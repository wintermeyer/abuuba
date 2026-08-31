defmodule Abuuba.Federation.Inbox do
  @moduledoc """
  Deciding whether an activity that arrived is one we want.

  An inbox is a public endpoint that anybody may POST to, so "it was signed"
  answers who sent it and nothing about whether we asked. Two filters stand
  between arrival and work.

  ## Relevance

  A relay, or a helpful stranger, can forward every public post on the
  fediverse to our inbox. Signature checks pass, because the sender really is
  who they say; storing it all would still fill this database with posts nobody
  here follows. So a public or unlisted activity is only processed when it is
  connected to something local: somebody here follows the actor, it addresses
  somebody here, or it replies to a post of ours.

  Anything not public is exempt from that test. A direct message from a
  stranger is unsolicited by definition, and refusing it because no local
  account follows the sender would mean nobody could ever be contacted for the
  first time.

  ## Tombstones

  A `Delete` arrives many times: the sender retries, several local recipients
  share an inbox, a relay repeats it. Each redelivery would otherwise become a
  fetch for an object that no longer exists, which is a request to a server
  that has already told us the answer. So a delete is remembered for a while
  and a repeat of it costs nothing.
  """

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Federation.JSONLD
  alias Abuuba.Federation.URIs
  alias Abuuba.Moderation.Domains
  alias Abuuba.Relationships.Follow
  alias Abuuba.Repo
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Status

  @tombstone_ttl_seconds 6 * 60 * 60

  @public JSONLD.public()

  @doc """
  Whether an activity is worth doing work for.
  """
  @spec relevant?(map()) :: boolean()
  def relevant?(activity) when is_map(activity) do
    if public_or_unlisted?(activity) do
      addresses_local_account?(activity) or
        from_followed_actor?(activity) or
        replies_to_local_status?(activity)
    else
      # Not public, so it was aimed at somebody rather than broadcast. Refusing
      # it for want of an existing relationship would mean nobody here could
      # ever be contacted for the first time.
      true
    end
  end

  def relevant?(_activity), do: false

  @doc """
  Records that an object is gone.
  """
  @spec tombstone(String.t(), String.t()) :: :ok
  def tombstone(uri, kind \\ "Delete") when is_binary(uri) do
    Repo.insert_all(
      "tombstones",
      [[uri: uri, kind: kind, inserted_at: DateTime.utc_now()]],
      on_conflict: :nothing,
      conflict_target: [:uri]
    )

    :ok
  end

  @doc """
  Whether we have already been told this object is gone.
  """
  @spec tombstoned?(String.t() | nil) :: boolean()
  def tombstoned?(nil), do: false

  def tombstoned?(uri) when is_binary(uri) do
    cutoff = DateTime.add(DateTime.utc_now(), -@tombstone_ttl_seconds, :second)

    from(t in "tombstones", where: t.uri == ^uri and t.inserted_at > ^cutoff, select: 1, limit: 1)
    |> Repo.one()
    |> is_integer()
  end

  @doc """
  Forgets tombstones past their usefulness. For a periodic sweep.
  """
  @spec sweep_tombstones() :: non_neg_integer()
  def sweep_tombstones do
    cutoff = DateTime.add(DateTime.utc_now(), -@tombstone_ttl_seconds, :second)

    {deleted, _} =
      from(t in "tombstones", where: t.inserted_at <= ^cutoff) |> Repo.delete_all()

    deleted
  end

  @doc """
  Whether an activity concerns an actor or object we have never heard of and
  never will.

  A `Delete` or `Update` for something unknown is not an error and not work: we
  cannot delete what we do not have, and fetching to find out would be a
  request for an object the sender has just told us is gone.
  """
  @spec no_op?(map()) :: boolean()
  def no_op?(%{"type" => type} = activity) when type in ["Delete", "Update"] do
    uri = object_uri(activity)

    cond do
      is_nil(uri) -> true
      tombstoned?(uri) -> true
      type == "Delete" -> not known?(uri)
      true -> false
    end
  end

  def no_op?(_activity), do: false

  @doc """
  The URI an activity's object refers to, however it is written.
  """
  @spec object_uri(map()) :: String.t() | nil
  def object_uri(%{"object" => object}), do: uri_of(object)
  def object_uri(_activity), do: nil

  defp uri_of(value) when is_binary(value), do: value
  defp uri_of(%{"id" => id}) when is_binary(id), do: id
  defp uri_of(_value), do: nil

  ## Relevance tests

  defp public_or_unlisted?(activity) do
    audience = addressees(activity["to"]) ++ addressees(activity["cc"])

    @public in audience
  end

  defp addressees(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp addressees(value) when is_binary(value), do: [value]
  defp addressees(_value), do: []

  defp addresses_local_account?(activity) do
    (addressees(activity["to"]) ++ addressees(activity["cc"]))
    |> Enum.any?(&(not is_nil(Helpers.local_account(&1))))
  end

  defp from_followed_actor?(activity) do
    case actor_uri(activity) do
      nil ->
        false

      uri ->
        Follow
        |> join(:inner, [f], target in Account, on: target.id == f.target_account_id)
        |> join(:inner, [f, _target], follower in Account, on: follower.id == f.account_id)
        |> where([_f, target, follower], target.uri == ^uri and is_nil(follower.domain))
        |> Repo.exists?()
    end
  end

  defp replies_to_local_status?(activity) do
    case reply_target(activity) |> Statuses.get_status_unchecked_by_uri() do
      %Status{local: true} -> true
      _ -> false
    end
  end

  defp reply_target(%{"object" => %{"inReplyTo" => uri}}) when is_binary(uri), do: uri
  defp reply_target(%{"inReplyTo" => uri}) when is_binary(uri), do: uri
  defp reply_target(_activity), do: nil

  @doc """
  The actor an activity came from, however it is written.
  """
  @spec actor_uri(map()) :: String.t() | nil
  def actor_uri(%{"actor" => actor}), do: uri_of(actor)
  def actor_uri(_activity), do: nil

  @doc """
  Whether this server takes anything from the server behind an actor URI.

  Asked of the URI rather than of a resolved account, because the point is to
  refuse before doing any work: resolving the actor of an activity from a
  suspended domain means a request to that domain, which is the one thing a
  suspension says not to do.
  """
  @spec acceptable_actor?(String.t() | nil) :: boolean()
  def acceptable_actor?(nil), do: false
  def acceptable_actor?(uri), do: uri |> URIs.host_of() |> Domains.accepts_from?()

  @doc """
  Whether we already hold the object an activity refers to.
  """
  @spec known?(String.t() | nil) :: boolean()
  def known?(nil), do: false

  def known?(uri) do
    not is_nil(Statuses.get_status_unchecked_by_uri(uri)) or
      not is_nil(Accounts.get_account_by_uri(uri))
  end
end
