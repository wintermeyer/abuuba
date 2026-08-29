defmodule Abuuba.ModerationActionsTest do
  use Abuuba.DataCase, async: true
  use Oban.Testing, repo: Abuuba.Repo

  import Ecto.Query
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.User
  alias Abuuba.Moderation.Actions
  alias Abuuba.Moderation.Appeal
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Moderation.PurgeWorker
  alias Abuuba.Moderation.Reports
  alias Abuuba.Moderation.Strike
  alias Abuuba.Notifications
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Stats
  alias Abuuba.Timelines.Feed

  setup do
    %{moderator: account_fixture(), target: account_fixture()}
  end

  # Puts the grace window in the past without waiting 30 days for it.
  defp due(account) do
    from(a in Abuuba.Accounts.Account, where: a.id == ^account.id)
    |> Repo.update_all(set: [purge_after: DateTime.add(DateTime.utc_now(), -1, :day)])
  end

  defp feed_ids(account_id) do
    Feed.status_ids("home", account_id, %{})
  end

  describe "taking an action" do
    test "records what was decided, for the person it was decided about", %{
      moderator: moderator,
      target: target
    } do
      assert {:ok, strike} =
               Actions.take(moderator, target, "silence", text: "Please stop shouting.")

      assert strike.action == "silence"
      assert strike.text == "Please stop shouting."
      assert [^strike] = Actions.strikes(target)
    end

    test "tells them", %{moderator: moderator, target: target} do
      # An account silenced without being told is an account whose owner spends
      # a week wondering why nobody answers them.
      {:ok, _} = Actions.take(moderator, target, "silence")

      assert [%{type: "moderation_warning"}] = Notifications.list(target)
    end

    test "writes to the audit log", %{moderator: moderator, target: target} do
      {:ok, _} = Actions.take(moderator, target, "silence")

      assert [%{action: "account.silence"}] = AuditLog.for_target(:account, target.id)
    end

    test "a warning with no state change is still an action", %{
      moderator: moderator,
      target: target
    } do
      # Telling somebody is a moderation decision even when nothing else
      # happens, and the most common one.
      {:ok, strike} = Actions.take(moderator, target, "none", text: "A first warning.")

      assert strike.action == "none"
      assert Accounts.get_account(target.id).silenced_at == nil
      assert [_] = Actions.strikes(target)
    end

    test "refuses an action nobody defined", %{moderator: moderator, target: target} do
      assert {:error, :unknown_action} = Actions.take(moderator, target, "banish")
    end
  end

  describe "the ladder" do
    test "silencing hides them from strangers", %{moderator: moderator, target: target} do
      {:ok, _} = Actions.take(moderator, target, "silence")

      assert Accounts.get_account(target.id).silenced_at
    end

    # What the mark then does to a post is `Abuuba.SensitizedAccountTest`; this is
    # only that the action records it.
    test "marking sensitive records the mark", %{moderator: moderator, target: target} do
      {:ok, _} = Actions.take(moderator, target, "mark_statuses_as_sensitive")

      assert Accounts.get_account(target.id).sensitized_at
    end

    test "disabling stops them signing in without hiding them", %{
      moderator: moderator,
      target: target
    } do
      user = user_fixture(%{account_id: target.id, approved: true})

      {:ok, _} = Actions.take(moderator, target, "disable")

      refute Repo.get(User, user.id).approved
      refute Accounts.get_account(target.id).suspended_at
    end

    test "a disabled account is not a registration waiting to be approved", %{
      moderator: moderator,
      target: target
    } do
      # The two are one pair of columns: approved, and whether approval ever
      # happened. A disable that left the second one empty put the account in
      # the approval queue, where the next moderator could let them back in
      # while the sign-in page told them their registration was pending.
      user = user_fixture(%{account_id: target.id, approved: true})

      {:ok, _} = Actions.take(moderator, target, "disable")

      disabled = Repo.get(User, user.id)

      assert User.disabled?(disabled)
      refute disabled.id in Enum.map(Auth.pending_approval(), & &1.id)
    end

    test "and lifting it lets them straight back in", %{moderator: moderator, target: target} do
      user =
        user_fixture(%{account_id: target.id, approved: true, confirmed_at: DateTime.utc_now()})

      {:ok, strike} = Actions.take(moderator, target, "disable")
      {:ok, _overruled} = Actions.undo(moderator, strike)

      restored = Repo.get(User, user.id)

      refute User.disabled?(restored)
      assert Auth.check_sign_in(restored) == :ok
    end

    test "deleting posts refuses to mean all of them", %{moderator: moderator, target: target} do
      # Naming no posts is a moderator who has not said which, and reading it
      # as "every post this account ever wrote" is the most destructive
      # possible guess at what they meant.
      status = status_fixture(%{account_id: target.id})

      assert {:error, :no_statuses} = Actions.take(moderator, target, "delete_statuses")
      refute Repo.get(Abuuba.Statuses.Status, status.id).deleted_at
      assert Actions.strikes(target) == []
    end

    test "deleting posts deletes them", %{moderator: moderator, target: target} do
      status = status_fixture(%{account_id: target.id, text: "the offending post"})

      {:ok, _} = Actions.take(moderator, target, "delete_statuses", status_ids: [status.id])

      assert Repo.get(Abuuba.Statuses.Status, status.id).deleted_at
    end

    test "deleting posts moves the counters and clears them out of feeds", %{
      moderator: moderator,
      target: target
    } do
      # The moderator's deletion is the same deletion as the author's: it has
      # to leave the counter caches and the feeds in the state any other
      # deletion would.
      reader = account_fixture()
      {:ok, _} = Relationships.follow(reader, Accounts.get_account(target.id))
      status = status_fixture(%{account_id: target.id, text: "the offending post"})

      assert Stats.account_stats(target.id).statuses_count == 1
      assert status.id in feed_ids(reader.id)

      {:ok, _} = Actions.take(moderator, target, "delete_statuses", status_ids: [status.id])

      assert Stats.account_stats(target.id).statuses_count == 0
      refute status.id in feed_ids(reader.id)
    end

    test "suspending hides them now and schedules the purge for later", %{
      moderator: moderator,
      target: target
    } do
      # An appeal upheld after the purge is an apology with nothing to give
      # back, and the window is what makes reversing one mean something.
      {:ok, _} = Actions.take(moderator, target, "suspend")

      account = Accounts.get_account(target.id)

      assert account.suspended_at
      assert account.purge_after

      assert DateTime.diff(account.purge_after, DateTime.utc_now(), :day) >=
               Actions.grace_days() - 1
    end
  end

  describe "the purge" do
    test "takes a suspended account once its window has passed", %{
      moderator: moderator,
      target: target
    } do
      {:ok, _} = Actions.take(moderator, target, "suspend")
      due(target)

      assert :ok = perform_job(PurgeWorker, %{})

      refute Accounts.get_account(target.id)
    end

    test "leaves one whose window is still open", %{moderator: moderator, target: target} do
      # The window exists so an appeal can be heard while there is still
      # something to give back. Purging early throws that away.
      {:ok, _} = Actions.take(moderator, target, "suspend")

      assert :ok = perform_job(PurgeWorker, %{})

      assert Accounts.get_account(target.id)
    end

    test "leaves one whose suspension was lifted", %{moderator: moderator, target: target} do
      {:ok, strike} = Actions.take(moderator, target, "suspend")
      due(target)
      {:ok, _} = Actions.undo(moderator, strike)

      assert :ok = perform_job(PurgeWorker, %{})

      assert Accounts.get_account(target.id)
    end

    test "leaves everybody else alone", %{moderator: moderator, target: target} do
      bystander = account_fixture()
      {:ok, _} = Actions.take(moderator, target, "suspend")
      due(target)

      assert :ok = perform_job(PurgeWorker, %{})

      assert Accounts.get_account(bystander.id)
    end
  end

  describe "the report that prompted it" do
    test "is closed by the same act", %{moderator: moderator, target: target} do
      # A moderator who has taken the decision should not also have to remember
      # to close the thing that asked for it.
      {:ok, report} =
        Reports.create(account_fixture(), %{"target_account_id" => target.id})

      {:ok, _} = Actions.take(moderator, target, "silence", report: report)

      assert Reports.open_count() == 0
    end

    test "and named on the strike", %{moderator: moderator, target: target} do
      {:ok, report} = Reports.create(account_fixture(), %{"target_account_id" => target.id})

      {:ok, strike} = Actions.take(moderator, target, "silence", report: report)

      assert strike.report_id == report.id
    end
  end

  describe "undoing" do
    test "lifts a silencing", %{moderator: moderator, target: target} do
      {:ok, strike} = Actions.take(moderator, target, "silence")

      assert {:ok, overruled} = Actions.undo(moderator, strike)

      refute Accounts.get_account(target.id).silenced_at
      refute Strike.standing?(overruled)
    end

    test "lifts a suspension and cancels the purge", %{moderator: moderator, target: target} do
      {:ok, strike} = Actions.take(moderator, target, "suspend")

      {:ok, _} = Actions.undo(moderator, strike)

      account = Accounts.get_account(target.id)

      refute account.suspended_at
      refute account.purge_after
    end

    test "refuses to pretend a deletion can be taken back", %{
      moderator: moderator,
      target: target
    } do
      # An appeal against it can be upheld and the posts are still gone. Saying
      # so is better than a success that restored nothing.
      status = status_fixture(%{account_id: target.id})
      {:ok, strike} = Actions.take(moderator, target, "delete_statuses", status_ids: [status.id])

      assert {:error, :not_undoable} = Actions.undo(moderator, strike)
    end

    test "the record stays, marked overruled", %{moderator: moderator, target: target} do
      # The decision was made and later reversed. Erasing it would leave the
      # appeal pointing at nothing.
      {:ok, strike} = Actions.take(moderator, target, "silence")
      {:ok, _} = Actions.undo(moderator, strike)

      assert [kept] = Actions.strikes(target)
      assert kept.overruled_at
    end
  end

  describe "appealing" do
    setup %{moderator: moderator, target: target} do
      {:ok, strike} = Actions.take(moderator, target, "silence", text: "Stop.")

      %{strike: strike}
    end

    test "somebody may appeal their own strike", %{target: target, strike: strike} do
      assert {:ok, appeal} = Actions.appeal(target, strike, "I did not do that.")
      assert Appeal.pending?(appeal)
    end

    test "and nobody else's", %{strike: strike} do
      assert {:error, :not_yours} =
               Actions.appeal(account_fixture(), strike, "Not my business.")
    end

    test "only once", %{target: target, strike: strike} do
      {:ok, _} = Actions.appeal(target, strike, "First try.")

      assert {:error, changeset} = Actions.appeal(target, strike, "Second try.")
      assert %{account_warning_id: [_]} = errors_on(changeset)
    end

    test "not after the window has closed", %{target: target, strike: strike} do
      old = DateTime.add(DateTime.utc_now(), -(Appeal.window_days() + 1), :day)
      {:ok, strike} = strike |> Ecto.Changeset.change(inserted_at: old) |> Repo.update()

      assert {:error, :too_late} = Actions.appeal(target, strike, "Late.")
    end

    test "not with nothing in it", %{target: target, strike: strike} do
      assert {:error, changeset} = Actions.appeal(target, strike, "")
      assert %{text: [_]} = errors_on(changeset)
    end
  end

  describe "deciding an appeal" do
    setup %{moderator: moderator, target: target} do
      {:ok, strike} = Actions.take(moderator, target, "silence")
      {:ok, appeal} = Actions.appeal(target, strike, "I did not do that.")

      %{strike: strike, appeal: appeal}
    end

    test "upholding it undoes the action", %{moderator: moderator, target: target, appeal: appeal} do
      assert {:ok, decided} = Actions.approve_appeal(moderator, appeal)

      refute Appeal.pending?(decided)
      refute Accounts.get_account(target.id).silenced_at
    end

    test "upholding one against something undoable still records it", %{
      moderator: moderator,
      target: target
    } do
      # The person was right and the record should say so, even where nothing
      # can be given back.
      status = status_fixture(%{account_id: target.id})
      {:ok, strike} = Actions.take(moderator, target, "delete_statuses", status_ids: [status.id])
      {:ok, appeal} = Actions.appeal(target, strike, "Those were fine.")

      assert {:ok, decided} = Actions.approve_appeal(moderator, appeal)
      assert decided.approved_at
    end

    test "turning it down leaves the action standing", %{
      moderator: moderator,
      target: target,
      appeal: appeal
    } do
      assert {:ok, decided} = Actions.reject_appeal(moderator, appeal)

      assert decided.rejected_at
      assert Accounts.get_account(target.id).silenced_at
    end

    test "either way the person is told", %{moderator: moderator, target: target, appeal: appeal} do
      Notifications.clear(target)

      {:ok, _} = Actions.reject_appeal(moderator, appeal)

      assert [_] = Notifications.list(target)
    end

    test "waiting appeals can be listed", %{appeal: appeal} do
      assert [pending] = Actions.pending_appeals()
      assert pending.id == appeal.id
    end

    test "and stop waiting once decided", %{moderator: moderator, appeal: appeal} do
      {:ok, _} = Actions.reject_appeal(moderator, appeal)

      assert Actions.pending_appeals() == []
    end
  end

  describe "what somebody may read about themselves" do
    test "their own strikes", %{moderator: moderator, target: target} do
      {:ok, strike} = Actions.take(moderator, target, "silence")

      assert Actions.own_strike(target, strike.id).id == strike.id
    end

    test "and nobody else's", %{moderator: moderator, target: target} do
      {:ok, strike} = Actions.take(moderator, target, "silence")

      assert Actions.own_strike(account_fixture(), strike.id) == nil
    end
  end

  describe "moderator notes" do
    test "are kept against an account", %{moderator: moderator, target: target} do
      :ok = Actions.add_note(moderator, :account, target.id, "Seen this pattern before.")

      assert [note] = Actions.notes(:account, target.id)
      assert note.content == "Seen this pattern before."
      assert note.account_id == moderator.id
    end

    test "and against a report", %{moderator: moderator, target: target} do
      {:ok, report} = Reports.create(account_fixture(), %{"target_account_id" => target.id})

      :ok = Actions.add_note(moderator, :report, report.id, "Same person as last month.")

      assert [_] = Actions.notes(:report, report.id)
    end
  end
end
