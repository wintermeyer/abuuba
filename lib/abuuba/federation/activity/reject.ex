defmodule Abuuba.Federation.Activity.Reject do
  @moduledoc """
  A remote account turned down a follow, or took one back.

  Removes both the pending request and any follow, because a `Reject` for an
  already-accepted follow is how a server says "actually, no longer": a remote
  account that blocks somebody sends one.

  A relay turning our subscription down arrives here too, recognised by the
  `Follow` id it names. See `Abuuba.Federation.Activity.Accept`.
  """

  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Federation.Relays
  alias Abuuba.Relationships

  @doc false
  def handle(activity, opts \\ []) do
    case Relays.reject(Helpers.uri_of(activity["object"]), opts[:actor_uri]) do
      {:ok, _relay} -> :ok
      # Somebody else's server naming one of our relay Follows. See
      # `Abuuba.Federation.Activity.Accept`.
      {:error, :wrong_host} -> :ok
      :error -> handle_account_follow(activity, opts)
    end
  end

  defp handle_account_follow(activity, opts) do
    with {:ok, target} <- Helpers.actor(activity, opts),
         follower when not is_nil(follower) <- follower_from(activity) do
      case Relationships.get_follow_request(follower, target) do
        nil -> :ok
        request -> Relationships.reject_follow_request(request)
      end

      Relationships.unfollow(follower, target)
    else
      _ -> :ok
    end
  end

  defp follower_from(activity) do
    case activity["object"] do
      %{"actor" => actor} -> Helpers.local_account(Helpers.uri_of(actor))
      _ -> nil
    end
  end
end
