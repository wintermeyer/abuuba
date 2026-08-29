defmodule AbuubaWeb.AdminAppealsTest do
  @moduledoc """
  The appeal queue: what a moderator sees, and the two decisions they can take.

  A strike is the server telling somebody they did something wrong, and an
  appeal is that person saying it was a mistake. Before this screen existed the
  appeal reached the database and stopped there, so the tests that matter most
  here are the ones asserting a decision changes the account, not just the row.
  """

  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Auth
  alias Abuuba.Moderation.Actions
  alias Abuuba.Moderation.Appeal
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Roles

  setup %{conn: conn} do
    moderator = staff(["view_dashboard", "manage_users", "manage_appeals"])
    moderator_account = Accounts.get_account(moderator.account_id)
    target = account_fixture()

    {:ok, strike} = Actions.take(moderator_account, target, "silence")
    {:ok, appeal} = Actions.appeal(target, strike, "I did not do that.")

    %{
      conn: log_in(conn, moderator),
      moderator: moderator,
      moderator_account: moderator_account,
      target: target,
      strike: strike,
      appeal: appeal
    }
  end

  describe "the queue" do
    test "lists an appeal waiting to be decided", %{conn: conn, target: target} do
      {:ok, _live, html} = live(conn, ~p"/admin/appeals")

      assert html =~ "I did not do that."
      assert html =~ target.username
    end

    test "says so when there is nothing waiting", %{conn: conn, appeal: appeal} do
      {:ok, _} = Actions.reject_appeal(Accounts.get_account(appeal.account_id), appeal)

      {:ok, _live, html} = live(conn, ~p"/admin/appeals")

      assert html =~ "Nothing is waiting"
    end

    test "the dashboard links to it", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin")

      assert html =~ ~p"/admin/appeals"
    end

    # The count still shows, because the dashboard is a picture of what is
    # waiting. Only the link goes, since it would answer "not allowed".
    test "and does not link for somebody who may not answer them" do
      plain = log_in(build_conn(), staff(["view_dashboard"]))

      {:ok, _live, html} = live(plain, ~p"/admin")

      refute html =~ ~p"/admin/appeals"
      assert html =~ "Appeals waiting"
    end
  end

  describe "upholding an appeal" do
    test "undoes the action and records the decision", %{
      conn: conn,
      target: target,
      appeal: appeal
    } do
      {:ok, live, _html} = live(conn, ~p"/admin/appeals")

      live
      |> element("button[phx-value-appeal='#{appeal.id}'][phx-click='approve_appeal']")
      |> render_click()

      refute Accounts.get_account(target.id).silenced_at
      refute Appeal.pending?(Actions.appeal_for(appeal.account_warning_id))
    end

    test "writes to the audit log", %{conn: conn, appeal: appeal} do
      {:ok, live, _html} = live(conn, ~p"/admin/appeals")

      live
      |> element("button[phx-value-appeal='#{appeal.id}'][phx-click='approve_appeal']")
      |> render_click()

      assert [%{action: "appeal.approve"}] = AuditLog.for_target(:appeal, appeal.id)
    end
  end

  describe "turning an appeal down" do
    test "leaves the action in place and records the decision", %{
      conn: conn,
      target: target,
      appeal: appeal
    } do
      {:ok, live, _html} = live(conn, ~p"/admin/appeals")

      live
      |> element("button[phx-value-appeal='#{appeal.id}'][phx-click='reject_appeal']")
      |> render_click()

      assert Accounts.get_account(target.id).silenced_at
      refute Appeal.pending?(Actions.appeal_for(appeal.account_warning_id))
    end
  end

  describe "an appeal that is already answered" do
    # The queue only lists undecided appeals, so this arrives as an event from
    # the other end of the socket rather than from the page. `decision_changeset/2`
    # sets one timestamp without clearing the other, so deciding twice would
    # leave an appeal both upheld and turned down, and lift the strike again.
    test "cannot be decided a second time", %{conn: conn, appeal: appeal, target: target} do
      {:ok, _} = Actions.reject_appeal(Accounts.get_account(appeal.account_id), appeal)

      {:ok, live, _html} = live(conn, ~p"/admin/appeals")
      render_click(live, "approve_appeal", %{"appeal" => to_string(appeal.id)})

      decided = Actions.appeal_for(appeal.account_warning_id)

      assert decided.rejected_at
      refute decided.approved_at
      assert Accounts.get_account(target.id).silenced_at
    end
  end

  describe "permissions" do
    # Upholding an appeal reaches `Actions.undo/2`, which the account screen
    # refuses when the subject outranks the moderator. Without the same check
    # here the queue would be a second way in.
    test "somebody who outranks the moderator cannot have their appeal decided", %{
      conn: conn,
      moderator_account: moderator_account
    } do
      # position 990 against the setup moderator's 900.
      senior = staff_at(990, ["manage_users"])
      senior_account = Accounts.get_account(senior.account_id)

      {:ok, strike} = Actions.take(moderator_account, senior_account, "silence")
      {:ok, appeal} = Actions.appeal(senior_account, strike, "This was wrong.")

      {:ok, live, _html} = live(conn, ~p"/admin/appeals")
      render_click(live, "approve_appeal", %{"appeal" => to_string(appeal.id)})

      assert Accounts.get_account(senior_account.id).silenced_at
      assert Appeal.pending?(Actions.appeal_for(strike.id))
    end

    test "a role without manage_appeals cannot open the screen" do
      plain = log_in(build_conn(), staff(["manage_users"]))

      assert {:error, {:live_redirect, _}} = live(plain, ~p"/admin/appeals")
    end

    test "and cannot decide by sending the event either", %{appeal: appeal, target: target} do
      plain = log_in(build_conn(), staff(["manage_users"]))

      # A screen they may open, so the refusal under test is the event's own
      # and not the section gate answering first.
      {:ok, live, _html} = live(plain, ~p"/admin/accounts")
      render_click(live, "approve_appeal", %{"appeal" => to_string(appeal.id)})

      assert Accounts.get_account(target.id).silenced_at
      assert Appeal.pending?(Actions.appeal_for(appeal.account_warning_id))
    end
  end

  defp staff(permissions), do: staff_at(900, permissions)

  defp staff_at(position, permissions) do
    {:ok, role} =
      Roles.create(%{
        name: "Role #{System.unique_integer([:positive])}",
        position: position,
        permissions: Roles.mask(permissions)
      })

    user =
      user_fixture(%{
        account_id: account_fixture().id,
        approved: true,
        confirmed_at: DateTime.utc_now()
      })

    {:ok, user} = Roles.assign(user, role)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end
end
