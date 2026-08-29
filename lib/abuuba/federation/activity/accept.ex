defmodule Abuuba.Federation.Activity.Accept do
  @moduledoc """
  A remote account agreed to a follow we asked for.

  Turns our pending request into a follow. Idempotent: an `Accept` that arrives
  twice finds no request the second time and does nothing.

  A relay answering our subscription arrives here too, and is recognised by the
  `Follow` id it names rather than by the actor: a relay's subscription is a
  follow of the public collection, so there is no account on either side of it.
  """

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Relays
  alias Abuuba.Relationships
  alias Abuuba.Relationships.FollowRequest
  alias Abuuba.Repo

  @doc false
  def handle(activity, opts \\ []) do
    case Relays.accept(Helpers.uri_of(activity["object"]), opts[:actor_uri]) do
      {:ok, _relay} -> :ok
      # Somebody else's server naming one of our relay Follows. It is not an
      # account follow either, so it stops here rather than falling through.
      {:error, :wrong_host} -> :ok
      :error -> handle_account_follow(activity, opts)
    end
  end

  defp handle_account_follow(activity, opts) do
    with {:ok, target} <- Helpers.actor(activity, opts),
         %{} = request <- pending_request(activity, target) do
      case Relationships.accept_follow_request(request) do
        {:ok, _follow} -> :ok
        # Already a follow. A redelivery.
        {:error, %Ecto.Changeset{}} -> :ok
        error -> error
      end
    else
      _ -> :ok
    end
  end

  # Matched by the follow activity's own id where the peer echoes it, and by
  # the pair of accounts otherwise. Some servers send back only the object URI.
  defp pending_request(activity, target) do
    case follower_from(activity) do
      nil -> nil
      follower -> Relationships.get_follow_request(follower, target)
    end
  end

  defp follower_from(activity) do
    case activity["object"] do
      %{"actor" => actor} -> Helpers.local_account(Helpers.uri_of(actor))
      uri when is_binary(uri) -> by_follow_uri(uri)
      _ -> nil
    end
  end

  defp by_follow_uri(uri) do
    case Repo.get_by(FollowRequest, uri: uri) do
      nil -> by_our_own_follow_id(uri)
      request -> Repo.get(Account, request.account_id)
    end
  end

  # A Follow we sent carries an id we build rather than one we store --
  # `<actor>#follows/<request id>` -- so the row is found by reading it back
  # rather than by looking it up.
  #
  # Without this, a peer that echoes only the id has named something abuuba
  # cannot match, and the request stays pending for ever while its server
  # believes the follow is done. Mastodon echoes the whole Follow object and is
  # matched by the actor inside it; GoToSocial echoes the id.
  #
  # The actor in the id has to be the account whose request it is. The id is
  # ours to build, so a peer could otherwise name any request and have us
  # complete a follow somebody else asked for.
  defp by_our_own_follow_id(uri) do
    with [actor_uri, "follows/" <> id] <- String.split(uri, "#", parts: 2),
         {request_id, ""} <- Integer.parse(id),
         %FollowRequest{} = request <- Repo.get(FollowRequest, request_id),
         %Account{} = follower <- Repo.get(Account, request.account_id),
         ^actor_uri <- Actor.id(follower) do
      follower
    else
      _not_ours -> nil
    end
  end
end
