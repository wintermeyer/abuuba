defmodule Abuuba.Federation.Activity.Undo do
  @moduledoc """
  Taking something back: an unfollow, an unlike, an unboost, an unblock.

  The object is usually the whole activity being undone, which says plainly
  what kind of thing it was. Some servers send only its URI, though, and then
  there is nothing to read the type off. Rather than give up, each of the
  things an `Undo` can refer to is looked for by that URI, and whichever one
  exists is the one being taken back. Only one can be, since the URI is the
  activity's own id.

  Every branch is a no-op when there is nothing to undo. An `Undo` for
  something already undone, or never done, is ordinary: the sender retried, or
  our copy was already gone.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Relationships
  alias Abuuba.Relationships.Follow
  alias Abuuba.Relationships.FollowRequest
  alias Abuuba.Repo
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Status

  @doc false
  def handle(activity, opts \\ []) do
    case activity["object"] do
      %{"type" => type} = object -> undo(type, object, activity, opts)
      uri when is_binary(uri) -> undo_by_uri(uri, activity, opts)
      _ -> :ok
    end
  end

  defp undo("Follow", object, activity, opts) do
    with {:ok, follower} <- Helpers.actor(activity, opts),
         target when not is_nil(target) <- Helpers.local_account(Helpers.uri_of(object["object"])) do
      drop_follow(follower, target)
    else
      _ -> :ok
    end
  end

  defp undo("Like", object, activity, opts) do
    with {:ok, account} <- Helpers.actor(activity, opts),
         status when not is_nil(status) <-
           Statuses.get_status_unchecked_by_uri(Helpers.uri_of(object["object"])) do
      Statuses.unfavourite(account, status)
    else
      _ -> :ok
    end
  end

  defp undo("Announce", object, activity, opts) do
    with {:ok, account} <- Helpers.actor(activity, opts),
         status when not is_nil(status) <-
           Statuses.get_status_unchecked_by_uri(Helpers.uri_of(object["object"])) do
      Statuses.unboost(account, status)
    else
      _ -> :ok
    end
  end

  defp undo("Block", object, activity, opts) do
    with {:ok, blocker} <- Helpers.actor(activity, opts),
         target when not is_nil(target) <- Helpers.local_account(Helpers.uri_of(object["object"])) do
      Relationships.unblock(blocker, target)
    else
      _ -> :ok
    end
  end

  defp undo("Accept", _object, _activity, _opts), do: :ok

  defp undo(_type, _object, _activity, _opts), do: :ok

  # Only a URI to go on. Each thing an Undo can name is looked for by it, and
  # whichever exists is the one being taken back: the URI is the undone
  # activity's own id, so at most one can match.
  defp undo_by_uri(uri, _activity, _opts) do
    cond do
      follow = Repo.get_by(Follow, uri: uri) ->
        drop_follow_row(follow)

      request = Repo.get_by(FollowRequest, uri: uri) ->
        Relationships.reject_follow_request(request)

      status = boost_by_uri(uri) ->
        drop_boost(status)

      true ->
        :ok
    end
  end

  defp boost_by_uri(uri) do
    Status |> where([s], s.uri == ^uri and not is_nil(s.reblog_of_id)) |> Repo.one()
  end

  defp drop_boost(status) do
    with {:ok, _} <- Statuses.delete_status(status), do: :ok
  end

  defp drop_follow(follower, target), do: Relationships.unfollow(follower, target)

  defp drop_follow_row(follow) do
    follower = Repo.get(Account, follow.account_id)
    target = Repo.get(Account, follow.target_account_id)

    if follower && target, do: Relationships.unfollow(follower, target), else: :ok
  end
end
