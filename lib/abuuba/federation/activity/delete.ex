defmodule Abuuba.Federation.Activity.Delete do
  @moduledoc """
  Somebody removed something, or an account is going away.

  Two quite different jobs share one activity type, told apart by what the
  object is. A `Delete` naming the actor itself is an account deletion; one
  naming a post is a post deletion.

  Either way a tombstone is recorded, so that the many redeliveries this
  activity always gets cost nothing. See `Abuuba.Federation.Inbox`.
  """

  alias Abuuba.Accounts
  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Federation.Inbox
  alias Abuuba.Federation.ResolveStatus
  alias Abuuba.Repo
  alias Abuuba.Statuses

  @doc false
  def handle(activity, _opts \\ []) do
    actor_uri = Helpers.uri_of(activity["actor"])
    object_uri = Helpers.uri_of(activity["object"])

    cond do
      is_nil(object_uri) -> :ok
      object_uri == actor_uri -> delete_account(object_uri)
      true -> delete_status(object_uri, actor_uri)
    end
  end

  defp delete_account(uri) do
    Inbox.tombstone(uri, "Delete")

    case Helpers.known_account(uri) do
      nil -> :ok
      account -> with {:ok, _} <- Accounts.delete_account(account), do: :ok
    end
  end

  # Only the author may delete a post. Without this check a `Delete` from any
  # server would remove anybody's post, which is a one-line denial of service
  # against the whole network.
  defp delete_status(uri, actor_uri) do
    Inbox.tombstone(uri, "Delete")

    case Statuses.get_status_unchecked_by_uri(uri) do
      nil ->
        :ok

      status ->
        if authored_by?(status, actor_uri) do
          ResolveStatus.forget(uri)
        else
          :ok
        end
    end
  end

  defp authored_by?(status, actor_uri) do
    case Repo.get(Abuuba.Accounts.Account, status.account_id) do
      nil -> false
      account -> account.uri == actor_uri
    end
  end
end
