defmodule Abuuba.Federation.FollowerSync do
  @moduledoc """
  Telling a peer that its idea of who follows an account here is wrong.

  FEP-8fcf. Follower lists drift: a `Follow` or an `Undo` gets lost, a server
  is down for a day, an account is deleted while nobody is listening. Neither
  side notices, and the account quietly stops reaching people who think they
  are following it.

  The fix is a digest sent alongside every delivery to followers. A peer
  compares it with its own and, when they differ, fetches the one collection it
  is entitled to: its own accounts that follow ours. Neither side ever sends
  the whole list, and nothing happens at all in the normal case where the two
  agree.

  ## Why the XOR of hashes

  It does not depend on order, and adding then removing the same follower
  returns it to where it started. Both matter. Any hash of a concatenated list
  would need the two servers to agree on an ordering, and they never will:
  their rows were created at different times, in a different sequence, under
  different ids.

  ## One module for both halves

  The header advertises a URL and an endpoint answers it. Keeping the two in
  separate modules means keeping two URL builders in step by hand, and a peer
  sent to one address and served at another resyncs forever without converging.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Actor
  alias Abuuba.Relationships.Follow
  alias Abuuba.Repo

  @doc """
  The digest of a collection of follower URIs.
  """
  @spec digest([String.t()]) :: String.t()
  def digest(uris) do
    uris
    |> Enum.reduce(<<0::256>>, fn uri, acc -> xor(acc, :crypto.hash(:sha256, uri)) end)
    |> Base.encode16(case: :lower)
  end

  defp xor(<<a::256>>, <<b::256>>), do: <<Bitwise.bxor(a, b)::256>>

  @doc """
  The account's followers collection.
  """
  @spec collection_id(Account.t()) :: String.t()
  def collection_id(%Account{} = account), do: Actor.followers_id(account)

  @doc """
  Where one server's slice of that collection is served.
  """
  @spec partial_collection_url(Account.t(), String.t()) :: String.t()
  def partial_collection_url(%Account{} = account, domain) do
    "#{collection_id(account)}?domain=#{URI.encode_www_form(domain)}"
  end

  @doc """
  The `Collection-Synchronization` header value for one domain.
  """
  @spec header(Account.t(), String.t()) :: String.t()
  def header(%Account{} = account, domain) do
    header(account, domain, account |> follower_uris_on(domain) |> digest())
  end

  @doc """
  The same header, for a digest already computed.

  Distribution works out every domain's digest in one pass over the follower
  list, because doing it per destination would walk the whole list once per
  server on the receiving end of a popular account.
  """
  @spec header(Account.t(), String.t(), String.t()) :: String.t()
  def header(%Account{} = account, domain, digest) do
    ~s(collectionId="#{collection_id(account)}", ) <>
      ~s(url="#{partial_collection_url(account, domain)}", digest="#{digest}")
  end

  @doc """
  The URIs of an account's followers on one domain, which is what a peer is
  allowed to ask about: its own.
  """
  @spec follower_uris_on(Account.t(), String.t()) :: [String.t()]
  def follower_uris_on(%Account{} = account, domain) do
    Follow
    |> join(:inner, [f], a in Account, on: a.id == f.account_id)
    |> where([f, a], f.target_account_id == ^account.id)
    |> where([_f, a], fragment("lower(?)", a.domain) == ^String.downcase(domain))
    |> select([_f, a], a.uri)
    |> order_by([_f, a], asc: a.id)
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The URIs of the accounts here that follow a remote account.

  The mirror image of `follower_uris_on/2`: that is what we tell a peer about
  its own users, and this is what a peer tells us about ours. Comparing the two
  digests is the whole mechanism, so they have to be built the same way, over
  the same shape of URI, or the two sides disagree forever without converging.
  """
  @spec local_follower_uris_of(Account.t()) :: [String.t()]
  def local_follower_uris_of(%Account{} = account) do
    Follow
    |> join(:inner, [f], a in Account, on: a.id == f.account_id)
    |> where([f, _a], f.target_account_id == ^account.id)
    |> where([_f, a], is_nil(a.domain))
    |> order_by([_f, a], asc: a.id)
    |> select([_f, a], a)
    |> Repo.all()
    # Derived rather than read: a local account has no `uri` column, and the
    # id we publish is the only name a peer knows it by.
    |> Enum.map(&Actor.id/1)
  end

  @doc """
  Reads a `Collection-Synchronization` header into its three parts.

  The same `key="value"` syntax the signature header uses, which is why it is
  parsed the same way. Anything missing a part is not a synchronisation
  request; a peer's malformed header must be ignored rather than acted on.
  """
  @spec parse_header(String.t() | nil) ::
          {:ok, %{collection_id: String.t(), url: String.t(), digest: String.t()}} | :error
  def parse_header(nil), do: :error

  def parse_header(raw) when is_binary(raw) do
    parts =
      ~r/([a-zA-Z]+)="([^"]*)"/
      |> Regex.scan(raw)
      |> Map.new(fn [_whole, key, value] -> {key, value} end)

    case parts do
      %{"collectionId" => collection_id, "url" => url, "digest" => digest} ->
        {:ok, %{collection_id: collection_id, url: url, digest: digest}}

      _ ->
        :error
    end
  end

  def parse_header(_raw), do: :error

  @doc """
  A digest per domain, from follower accounts already in hand.

  One pass rather than one query per destination server.
  """
  @spec digests_by_domain([Account.t() | map()]) :: %{String.t() => String.t()}
  def digests_by_domain(followers) do
    followers
    |> Enum.reject(&(is_nil(&1.domain) or is_nil(&1.uri)))
    |> Enum.group_by(&String.downcase(&1.domain), & &1.uri)
    |> Map.new(fn {domain, uris} -> {domain, digest(uris)} end)
  end
end
