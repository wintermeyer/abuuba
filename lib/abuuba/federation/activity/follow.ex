defmodule Abuuba.Federation.Activity.Follow do
  @moduledoc """
  Somebody wants to follow one of ours.

  The answer is sent back as an `Accept` or a `Reject`, and which one depends
  on the target: an account that approves its followers gets a pending request,
  and anybody else is accepted straight away.

  A block is answered with a `Reject` rather than with silence. Silence looks
  like a server that is down, so the requester's server retries forever; a
  `Reject` ends it.
  """

  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Federation.Delivery
  alias Abuuba.Federation.Serializer
  alias Abuuba.Relationships

  @doc false
  def handle(activity, opts \\ []) do
    with {:ok, follower} <- Helpers.actor(activity, opts),
         target when not is_nil(target) <-
           Helpers.local_account(Helpers.uri_of(activity["object"])) do
      respond(follower, target, activity)
    else
      # Not for anybody here, or an actor we cannot resolve. Neither is work.
      nil -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp respond(follower, target, activity) do
    cond do
      Relationships.blocking?(target, follower) ->
        reject(follower, target, activity)

      target.locked ->
        Relationships.request_follow(follower, target, %{uri: activity["id"]})
        :ok

      true ->
        accept(follower, target, activity)
    end
  end

  defp accept(follower, target, activity) do
    # Already following is not an error: this is a redelivery, and the sender
    # still needs the Accept it did not get last time.
    Relationships.follow(follower, target, %{uri: activity["id"]})

    send_back("Accept", follower, target, activity)
  end

  defp reject(follower, target, activity) do
    Relationships.unfollow(follower, target)

    send_back("Reject", follower, target, activity)
  end

  # Sent for real. This used to hand the answer to a `reply` function taken
  # from the options, waiting for delivery to exist -- and once it existed,
  # nothing was changed here. Only tests ever passed one, so every follow from
  # another server was recorded here and never answered: the asker's request
  # stayed pending for ever, while the test asserting an Accept was sent went
  # on passing because it supplied the function that production never did.
  defp send_back(type, follower, target, activity) do
    Delivery.deliver_to_account(follower, Serializer.answer_to(type, target, activity), target)
  end
end
