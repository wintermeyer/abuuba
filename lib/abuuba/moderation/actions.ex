defmodule Abuuba.Moderation.Actions do
  @moduledoc """
  Taking a decision about an account, and undoing one.

  ## Every action does the same five things

  Change the state, record a strike the account's owner can read, write to the
  audit log, resolve whatever report prompted it, and tell the person. Written
  once here rather than five times across five actions, because the one that
  gets forgotten is the fifth: an account silenced without being told is an
  account whose owner spends a week wondering why nobody answers them.

  ## Suspension keeps the data for a while

  A suspension hides everything immediately and schedules the purge for later.
  An appeal upheld after the purge is an apology with nothing to give back, and
  the window is what makes reversing one mean something.

  ## Some actions cannot be undone

  Deleting posts is one. The ladder says so in `Strike.undoable?/1` rather than
  discovering it at the moment somebody's appeal is upheld and there is nothing
  to restore.
  """

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.User
  alias Abuuba.Moderation.Appeal
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Moderation.Reports
  alias Abuuba.Moderation.Strike
  alias Abuuba.Notifications
  alias Abuuba.OAuth
  alias Abuuba.Repo
  alias Abuuba.Snowflake
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Status

  # How long a suspended account's content is kept before it is purged. Long
  # enough for an appeal to be filed and read, which is the only reason to keep
  # it at all.
  @grace_days 30

  @doc """
  How long a suspension keeps the data before purging it.
  """
  @spec grace_days() :: pos_integer()
  def grace_days, do: @grace_days

  @doc """
  Takes an action against an account.

      Actions.take(moderator, target, "silence", text: "Please stop.", report: report)
  """
  @spec take(Account.t(), Account.t(), String.t(), keyword()) ::
          {:ok, Strike.t()} | {:error, term()}
  def take(%Account{} = moderator, %Account{} = target, action, opts \\ []) do
    with :ok <- allowed?(action),
         {:ok, strike} <- apply_and_record(moderator, target, action, opts) do
      # After the commit, for the reason the comment inside the transaction
      # gives: a broadcast is the one thing here that does not come back when
      # it rolls back. Announced from inside, a suspension that failed on its
      # strike still threw every page of an account nobody had suspended back
      # to the sign-in screen -- and one that succeeded raced its own commit,
      # so a page redrawing on the message could read the rows from before it
      # and come back signed in.
      shut_the_pages(target, action)

      AuditLog.record(moderator, "account.#{action}", :account, target.id, %{
        "strike_id" => strike.id
      })

      resolve_report(opts[:report], moderator)
      # Told rather than left to notice. An account silenced without being told
      # is an account whose owner spends a week wondering why nobody answers.
      Notifications.notify(target, moderator, "moderation_warning")

      {:ok, strike}
    end
  end

  @doc """
  Lifts what an action did, where it can be lifted.
  """
  @spec undo(Account.t(), Strike.t()) :: {:ok, Strike.t()} | {:error, :not_undoable}
  def undo(%Account{} = moderator, %Strike{} = strike) do
    if Strike.undoable?(strike.action) do
      target = Accounts.get_account(strike.target_account_id)

      lift(target, strike.action)

      {:ok, overruled} =
        strike |> Strike.changeset(%{overruled_at: DateTime.utc_now()}) |> Repo.update()

      AuditLog.record(
        moderator,
        "account.undo.#{strike.action}",
        :account,
        strike.target_account_id
      )

      {:ok, overruled}
    else
      {:error, :not_undoable}
    end
  end

  @doc """
  What one account has been told about itself, newest first.
  """
  @spec strikes(Account.t() | integer(), map()) :: [Strike.t()]
  def strikes(target, page \\ %{})
  def strikes(%Account{id: id}, page), do: strikes(id, page)

  def strikes(target_id, page) do
    Strike
    |> where([s], s.target_account_id == ^target_id)
    |> order_by([s], desc: s.id)
    |> limit(^Map.get(page, :limit, 40))
    |> Repo.all()
  end

  @doc """
  One strike, scoped to whoever it is about.

  Scoped in the query rather than checked afterwards: one that cannot return
  somebody else's strike cannot show them one.
  """
  @spec own_strike(Account.t() | integer(), integer() | String.t()) :: Strike.t() | nil
  def own_strike(%Account{id: id}, strike_id), do: own_strike(id, strike_id)

  def own_strike(target_id, strike_id) do
    with {:ok, id} <- Snowflake.cast(strike_id) do
      Repo.get_by(Strike, id: id, target_account_id: target_id)
    end
  end

  ## Appeals

  @doc """
  Appeals a strike.

  Inside the window and once only. Somebody who can appeal twice can appeal
  until a different moderator happens to be reading, which is a lottery rather
  than an appeal.
  """
  @spec appeal(Account.t(), Strike.t(), String.t()) ::
          {:ok, Appeal.t()} | {:error, :too_late | :not_yours | Ecto.Changeset.t()}
  def appeal(%Account{id: account_id}, %Strike{} = strike, text) do
    cond do
      strike.target_account_id != account_id ->
        {:error, :not_yours}

      not Appeal.open?(strike) ->
        {:error, :too_late}

      true ->
        %Appeal{}
        |> Appeal.changeset(%{
          account_warning_id: strike.id,
          account_id: account_id,
          text: text
        })
        |> Repo.insert()
    end
  end

  @doc """
  Upholds an appeal, undoing the action where it can be undone.

  Where it cannot, the appeal is still recorded as upheld: the person was right
  and the record should say so, even where nothing can be given back.
  """
  @spec approve_appeal(Account.t(), Appeal.t()) :: {:ok, Appeal.t()}
  def approve_appeal(%Account{} = moderator, %Appeal{} = appeal) do
    strike = Repo.get(Strike, appeal.account_warning_id)

    undo(moderator, strike)

    {:ok, decided} =
      appeal
      |> Appeal.decision_changeset(%{
        approved_at: DateTime.utc_now(),
        approved_by_account_id: moderator.id
      })
      |> Repo.update()

    AuditLog.record(moderator, "appeal.approve", :appeal, appeal.id)
    Notifications.notify(strike.target_account_id, moderator.id, "moderation_warning")

    {:ok, decided}
  end

  @doc """
  Turns an appeal down.
  """
  @spec reject_appeal(Account.t(), Appeal.t()) :: {:ok, Appeal.t()}
  def reject_appeal(%Account{} = moderator, %Appeal{} = appeal) do
    {:ok, decided} =
      appeal
      |> Appeal.decision_changeset(%{
        rejected_at: DateTime.utc_now(),
        approved_by_account_id: moderator.id
      })
      |> Repo.update()

    AuditLog.record(moderator, "appeal.reject", :appeal, appeal.id)
    Notifications.notify(appeal.account_id, moderator.id, "moderation_warning")

    {:ok, decided}
  end

  @doc """
  Appeals nobody has decided yet.

  Oldest first, because an appeal is somebody waiting on an answer and the one
  that has waited longest should be read first. The appellant and the strike
  come with it: a queue that named neither would be a list of paragraphs with
  nothing to decide about.
  """
  @spec pending_appeals(map()) :: [Appeal.t()]
  def pending_appeals(page \\ %{}) do
    Appeal
    |> where([a], is_nil(a.approved_at) and is_nil(a.rejected_at))
    |> order_by([a], asc: a.id)
    |> limit(^Map.get(page, :limit, 40))
    |> preload([:account, :account_warning])
    |> Repo.all()
  end

  @doc """
  One undecided appeal by id, with its appellant and strike, or `nil`.

  Scoped to the undecided ones on purpose. A decision arrives as an event from
  whatever is on the other end of a socket rather than from the page that was
  rendered, so "already answered" has to be a query that cannot return it and
  not a check somebody remembers to write: `decision_changeset/2` sets one
  timestamp without clearing the other, and upholding an appeal a second time
  would lift the same strike twice.
  """
  @spec get_pending_appeal(integer() | String.t()) :: Appeal.t() | nil
  def get_pending_appeal(id) do
    Appeal
    |> where([a], a.id == ^id and is_nil(a.approved_at) and is_nil(a.rejected_at))
    |> preload([:account, :account_warning])
    |> Repo.one()
  end

  @doc """
  How many appeals nobody has decided yet.
  """
  @spec pending_appeal_count() :: non_neg_integer()
  def pending_appeal_count do
    Appeal
    |> where([a], is_nil(a.approved_at) and is_nil(a.rejected_at))
    |> Repo.aggregate(:count)
  end

  @doc """
  The appeal against one strike, or `nil`.
  """
  @spec appeal_for(Strike.t() | integer()) :: Appeal.t() | nil
  def appeal_for(%Strike{id: id}), do: appeal_for(id)
  def appeal_for(strike_id), do: Repo.get_by(Appeal, account_warning_id: strike_id)

  @doc """
  The appeals against a list of strikes, keyed by strike.

  One query rather than one per strike: the page that shows somebody their
  strikes shows all of them at once.
  """
  @spec appeals_for([Strike.t()]) :: %{integer() => Appeal.t()}
  def appeals_for([]), do: %{}

  def appeals_for(strikes) do
    ids = Enum.map(strikes, & &1.id)

    Appeal
    |> where([a], a.account_warning_id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.account_warning_id, &1})
  end

  ## Notes

  @doc """
  Writes a note moderators can read and the account cannot.

  "We have seen this pattern before" is exactly the sort of thing that has to
  be written down and exactly the sort of thing that must not be handed to
  whoever it is about.
  """
  @spec add_note(Account.t(), atom() | String.t(), integer(), String.t()) :: :ok
  def add_note(%Account{id: author_id}, target_type, target_id, content) do
    now = DateTime.utc_now()

    Repo.insert_all("moderation_notes", [
      [
        account_id: author_id,
        target_type: to_string(target_type),
        target_id: target_id,
        content: String.slice(to_string(content), 0, 5_000),
        inserted_at: now,
        updated_at: now
      ]
    ])

    :ok
  end

  @doc """
  Notes about one thing, oldest first.
  """
  @spec notes(atom() | String.t(), integer()) :: [map()]
  def notes(target_type, target_id) do
    from(n in "moderation_notes",
      where: n.target_type == ^to_string(target_type) and n.target_id == ^target_id,
      order_by: [asc: n.id],
      select: %{
        id: n.id,
        account_id: n.account_id,
        content: n.content,
        inserted_at: n.inserted_at
      }
    )
    |> Repo.all()
  end

  ## Applying

  # The state change and the record of it go together or not at all: a
  # suspension with no strike behind it is somebody locked out with nothing to
  # read and nothing to appeal.
  defp apply_and_record(moderator, target, action, opts) do
    changeset = strike_changeset(moderator, target, action, opts)

    Repo.transaction(fn ->
      # The strike is checked for validity before the action is applied, not
      # only written after it. Applying one can tell every connected client
      # what happened — deleting posts publishes a `delete` on every topic
      # they reached — and a broadcast is the one thing here that does not come
      # back when the transaction rolls back. A note over the length limit
      # would otherwise leave every open client hiding posts that are still in
      # the database, until somebody reloaded the page.
      with {:ok, _valid} <- Ecto.Changeset.apply_action(changeset, :insert),
           {:ok, _account} <- apply_action(target, action, opts),
           {:ok, strike} <- Repo.insert(changeset) do
        strike
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp allowed?(action) do
    if action in Strike.actions(), do: :ok, else: {:error, :unknown_action}
  end

  defp apply_action(target, "none", _opts), do: {:ok, target}

  defp apply_action(target, "disable", _opts) do
    # The account stays; its owner cannot sign in. Distinct from a suspension,
    # which hides them from everybody else too.
    case Repo.get_by(User, account_id: target.id) do
      nil ->
        {:ok, target}

      user ->
        with {:ok, _} <- disable_user(user) do
          close_the_door(target)

          {:ok, target}
        end
    end
  end

  defp apply_action(target, "mark_statuses_as_sensitive", _opts) do
    Accounts.update_moderation(target, %{sensitized_at: DateTime.utc_now()})
  end

  # Naming no posts is a moderator who has not said which, and reading that as
  # "every post this account ever wrote" is the most destructive possible guess
  # at what they meant. Suspension is the action that covers everything.
  defp apply_action(target, "delete_statuses", opts) do
    case Keyword.get(opts, :status_ids, []) do
      [] ->
        {:error, :no_statuses}

      ids ->
        # Through `delete_status/1` rather than a bare update, because the
        # moderator's deletion is the same deletion as the author's: it moves
        # the counter caches, leaves feeds, and tells whoever is watching.
        Status
        |> where([s], s.account_id == ^target.id and s.id in ^ids)
        |> where([s], is_nil(s.deleted_at))
        |> Repo.all()
        |> Enum.each(&Statuses.delete_status/1)

        {:ok, target}
    end
  end

  defp apply_action(target, "silence", _opts) do
    Accounts.update_moderation(target, %{silenced_at: DateTime.utc_now()})
  end

  defp apply_action(target, "suspend", _opts) do
    # Hidden now, purged later. An appeal upheld after the purge is an apology
    # with nothing to give back.
    now = DateTime.utc_now()

    with {:ok, updated} <-
           Accounts.update_moderation(target, %{
             suspended_at: now,
             purge_after: DateTime.add(now, @grace_days, :day)
           }) do
      close_the_door(target)

      {:ok, updated}
    end
  end

  # Every request checks whether the account is still in good standing, so a
  # session left open is refused rather than honoured. These go anyway: a
  # session token and an app token are live credentials, and leaving them
  # valid means the decision holds only for as long as nobody finds a path
  # that forgets to look. Revoking the app tokens also closes the streaming
  # connections, which authenticate once and would otherwise go on delivering.
  defp close_the_door(target) do
    case Repo.get_by(User, account_id: target.id) do
      nil ->
        :ok

      user ->
        Auth.delete_all_session_tokens(user, announce: false)
        OAuth.revoke_all_for(user)
    end
  end

  # The half of `close_the_door/1` that has to wait for the commit.
  defp shut_the_pages(target, action) when action in ~w(suspend disable) do
    case Repo.get_by(User, account_id: target.id) do
      nil -> :ok
      user -> Auth.sessions_revoked(user)
    end
  end

  defp shut_the_pages(_target, _action), do: :ok

  defp lift(nil, _action), do: :ok

  defp lift(target, "suspend"),
    do: Accounts.update_moderation(target, %{suspended_at: nil, purge_after: nil})

  defp lift(target, "silence"), do: Accounts.update_moderation(target, %{silenced_at: nil})

  defp lift(target, "mark_statuses_as_sensitive"),
    do: Accounts.update_moderation(target, %{sensitized_at: nil})

  defp lift(target, "disable") do
    case Repo.get_by(User, account_id: target.id) do
      nil -> :ok
      user -> user |> User.enable_changeset() |> Repo.update()
    end
  end

  defp lift(_target, _action), do: :ok

  defp disable_user(user), do: user |> User.disable_changeset() |> Repo.update()

  defp strike_changeset(moderator, target, action, opts) do
    Strike.changeset(%Strike{}, %{
      account_id: moderator.id,
      target_account_id: target.id,
      action: action,
      text: Keyword.get(opts, :text, ""),
      status_ids: Keyword.get(opts, :status_ids, []),
      report_id: report_id(opts[:report])
    })
  end

  # The report that prompted it is dealt with by the same act. A moderator who
  # has taken the decision should not also have to remember to close the thing
  # that asked for it.
  defp resolve_report(nil, _moderator), do: :ok

  defp resolve_report(report, moderator) do
    Reports.resolve(report, moderator, %{"via" => "action"})

    :ok
  end

  defp report_id(nil), do: nil
  defp report_id(%{id: id}), do: id
end
