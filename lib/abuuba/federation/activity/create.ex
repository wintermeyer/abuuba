defmodule Abuuba.Federation.Activity.Create do
  @moduledoc """
  Somebody posted something.

  Idempotent by way of the object's URI: a redelivery finds the status already
  there and changes nothing. That matters more here than anywhere else, because
  a `Create` is the activity most likely to arrive twice, from the sender's
  retry and from a relay at the same time.
  """

  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Federation.ResolveStatus
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.Status

  @doc false
  def handle(activity, opts \\ []) do
    object = Helpers.object(activity)

    cond do
      is_nil(object) -> :ok
      # A server may post for its own accounts and for nobody else's. Without
      # this, an object internally consistent about its author — the id and the
      # `attributedTo` on one host — could be pushed here by any other server,
      # and this one would store somebody's words under somebody's name.
      not Helpers.speaks_for?(activity, object) -> :ok
      # Before the ordinary path, and it has to be: a vote is a Note with a
      # `name` and no content, and stored as a post it becomes a reply saying
      # "tea" -- a lost vote and a reply nobody wrote, in one delivery.
      vote?(object) -> record_vote(activity, object, opts)
      already_have?(object) -> :ok
      true -> store(object, opts)
    end
  end

  # A vote names an option and replies to the question. Nothing else on the
  # network has that shape, and a Note with body text is somebody talking
  # rather than voting.
  defp vote?(%{"name" => name, "inReplyTo" => in_reply_to})
       when is_binary(name) and not is_nil(in_reply_to),
       do: true

  defp vote?(_object), do: false

  defp record_vote(activity, object, opts) do
    with {:ok, voter} <- Helpers.actor(activity, opts),
         %Status{local: true} = status <- voted_on(object),
         %Poll{} = poll <- Statuses.get_poll(status),
         index when is_integer(index) <- Enum.find_index(poll.options, &(&1 == object["name"])) do
      Statuses.record_remote_vote(poll, voter, index)
    end

    # Whatever came of it. A vote for an option that does not exist, on a poll
    # that has closed, or from somebody who has already voted is not an error
    # to retry: the sender would send exactly the same thing again.
    :ok
  end

  # Only a poll of ours. A vote on somebody else's poll delivered here is
  # theirs to count, and counting it too would put a number in front of our
  # readers that their server never agreed with.
  defp voted_on(object) do
    object["inReplyTo"]
    |> Helpers.uri_of()
    |> case do
      nil -> nil
      uri -> Statuses.get_status_unchecked_by_uri(uri)
    end
  end

  defp already_have?(object) do
    object
    |> Helpers.uri_of()
    |> Statuses.get_status_unchecked_by_uri()
    |> is_nil()
    |> Kernel.not()
  end

  defp store(object, opts) do
    case ResolveStatus.from_document(object, opts) do
      {:ok, _status} ->
        :ok

      # A document we will not accept is not a job to retry. The attribution
      # rule will refuse it again in five minutes just as firmly.
      {:error, reason} when reason in [:untrustworthy_attribution, :unsupported_object_type] ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
