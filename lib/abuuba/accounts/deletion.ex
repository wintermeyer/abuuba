defmodule Abuuba.Accounts.Deletion do
  @moduledoc """
  Somebody closing their own account.

  ## Hidden now, gone shortly, and the name never comes back

  Three things happen at once and one happens later, and the split is the whole
  design.

  Immediately: the username is copied to `deleted_usernames`, the account is
  suspended so nothing of it is visible or reachable, the user row is deleted
  so nobody can sign in, every app's token and every outstanding authorization
  code is revoked, and a `Delete` is queued for every server that had reason to
  hear from this account.

  Shortly after: `Abuuba.Moderation.PurgeWorker` deletes the account row itself,
  and every foreign key hanging off it cascades — posts, follows, blocks,
  mutes, bookmarks, lists, filters, notifications, markers, conversations, the
  lot. That is the same path an admin deletion already takes, which is the
  point: one way of really deleting an account, tested by everything that
  already uses it.

  ## Why the row does not go immediately

  Because the signing key goes with it. Deliveries are queued jobs, and a job
  that runs after the key is deleted cannot sign, so it is dropped and no peer
  is ever told. Waiting a little lets the queue drain while the key still
  exists. The account is invisible and unusable throughout that window, so the
  wait costs nothing anybody can see.

  ## Why the name is copied rather than the row kept

  Keeping the row would keep the name, and it would also keep every row that
  cascades off it — a deletion that quietly retained the follows, blocks,
  bookmarks and media is a promise only discovered to be false in a breach. One
  table with one column costs nothing and says exactly what it means.
  """

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.DeletedUsername
  alias Abuuba.Accounts.User
  alias Abuuba.Federation.Delivery
  alias Abuuba.Federation.Serializer
  alias Abuuba.OAuth
  alias Abuuba.Repo

  # Long enough for the delivery queue to drain with the key still present,
  # short enough that nobody is waiting on it. The account is suspended for the
  # whole window, so nothing of it is reachable meanwhile.
  @purge_delay_minutes 30

  @doc """
  Whether a username belonged to an account somebody closed.
  """
  @spec username_taken?(String.t()) :: boolean()
  def username_taken?(username) when is_binary(username) do
    DeletedUsername
    |> where([d], fragment("lower(?) = lower(?)", d.username, ^username))
    |> Repo.exists?()
  end

  def username_taken?(_username), do: false

  @doc """
  How long an account waits between being closed and being deleted.
  """
  @spec purge_delay_minutes() :: pos_integer()
  def purge_delay_minutes, do: @purge_delay_minutes

  @doc """
  Closes an account at its owner's request.

  The password is checked here rather than in the page, next to the act it
  authorises. This is the one thing on the server that cannot be undone, and
  somebody who walked away from a signed-in browser should not have the account
  closed by whoever sits down next.
  """
  @spec delete_own_account(User.t(), String.t()) ::
          {:ok, Account.t()} | {:error, :invalid_password | :not_found | Ecto.Changeset.t()}
  def delete_own_account(%User{} = user, password) do
    if User.valid_password?(user, password) do
      case Accounts.get_account(user.account_id) do
        %Account{domain: nil, suspended_at: nil} = account -> close(account, user)
        _ -> {:error, :not_found}
      end
    else
      {:error, :invalid_password}
    end
  end

  @doc """
  Closes an account, without a password.

  Only for a moderator or a script. `close/2` looks the user up itself, so a
  caller cannot forget to pass one and leave somebody able to sign in to an
  account that is being deleted.
  """
  @spec close(Account.t(), User.t() | nil) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def close(%Account{domain: nil} = account, user \\ nil) do
    user = user || Accounts.get_user_by_account(account)

    # Queued while the account still has a key to sign with and followers to
    # address. The row survives until the purge precisely so these can be sent.
    announce(account)

    Repo.transaction(fn ->
      reserve(account)

      if user do
        OAuth.revoke_all_for(user)
        Repo.delete!(user)
      end

      case account |> Account.closing_changeset(purge_at()) |> Repo.update() do
        {:ok, closed} -> closed
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  ## Plumbing

  # Before anything else in the transaction, so that a failure anywhere leaves
  # the name unreserved rather than reserved for an account that is still open.
  defp reserve(account) do
    Repo.insert!(
      %DeletedUsername{username: account.username},
      on_conflict: :nothing,
      conflict_target: {:unsafe_fragment, "(lower(username))"}
    )
  end

  defp purge_at, do: DateTime.add(DateTime.utc_now(), @purge_delay_minutes * 60, :second)

  defp announce(account) do
    account
    |> Delivery.inboxes_for()
    |> Delivery.deliver_to(Serializer.delete_actor(account), account)
  rescue
    # Telling other servers is best effort. A peer that cannot be reached must
    # not be the reason somebody's account stays open.
    _error -> :ok
  end
end
