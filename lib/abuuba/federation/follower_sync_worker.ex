defmodule Abuuba.Federation.FollowerSyncWorker do
  @moduledoc """
  Repairing our idea of who here follows a remote account, once that account's
  server has told us the two disagree.

  The other half of `Abuuba.Federation.FollowerSync`. A peer attaches a digest to
  its deliveries; when ours differs, this fetches the one collection we are
  entitled to — the accounts here that its server thinks follow it — and
  reconciles.

  ## Two kinds of disagreement, handled differently

  **They list somebody who does not follow.** Their server will keep delivering
  to that account forever, so we send an `Undo` of a `Follow` we have no record
  of. It carries an id we made up, because the original was never ours; a peer
  that matches undos by activity id alone will ignore it, which is the same
  compromise the reference implementation makes. A pending follow request is a
  different story: they consider it granted, so it is authorised rather than
  withdrawn.

  **We list somebody they do not.** That is a follow we should not be showing,
  and removing it is destructive, so it happens only once the digest recomputed
  from what they actually sent matches the digest they claimed. Anything less
  and a truncated response, a paging bug or a half-fetched collection would
  silently unfollow people on their behalf.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.FollowerSync
  alias Abuuba.Federation.HTTP
  alias Abuuba.Federation.URIs
  alias Abuuba.Relationships

  # A follower list is one server's slice of one account's followers. Ten pages
  # of it is already an unusual instance; past that something is wrong with the
  # peer rather than with us, and walking forever is how one bad server becomes
  # our outage.
  @max_pages 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{"account_id" => account_id, "url" => url, "digest" => claimed} = args

    repair(account_id, url, claimed)
  end

  @doc """
  Fetches a peer's slice of one of our accounts' followers and reconciles.

  Separate from `perform/1` and taking a `:fetch` so a test can hand it a
  collection without a network. The host check is repeated here rather than
  trusted from the job: a queued job outlives the request that made it, and
  an argument that reaches an HTTP call is worth checking where the call is.
  """
  @spec repair(integer(), String.t(), String.t(), keyword()) :: :ok
  def repair(account_id, url, claimed, opts \\ []) do
    fetch = Keyword.get(opts, :fetch, &HTTP.get_json/1)

    with %Account{domain: domain} = account when not is_nil(domain) <-
           Accounts.get_account(account_id),
         true <- URIs.same_host?(account.uri, url),
         {:ok, uris} <- collect(url, [], 0, fetch) do
      reconcile(account, uris, claimed)
    else
      _ -> :ok
    end
  end

  @doc """
  Queues a repair, unless nothing about the header says one is needed.

  Every guard is here rather than in the worker so that the ordinary case,
  where the two sides already agree, costs one digest and no job at all.
  """
  @spec enqueue(Account.t(), String.t() | nil) :: :ok
  def enqueue(%Account{} = account, raw_header) do
    with {:ok, params} <- FollowerSync.parse_header(raw_header),
         true <-
           params.collection_id == account.followers_url || collection_matches?(account, params),
         # Only about their own collection, and only from their own host. A
         # header naming somebody else's collection is a peer asking us to
         # rewrite a relationship that is none of its business.
         true <- URIs.same_host?(account.uri, params.url),
         false <-
           FollowerSync.digest(FollowerSync.local_follower_uris_of(account)) == params.digest do
      %{account_id: account.id, url: params.url, digest: params.digest}
      |> new()
      |> Oban.insert()

      :ok
    else
      _ -> :ok
    end
  end

  # A peer's followers collection is whatever its actor document said, and for
  # a peer we resolved before that column was filled it is the conventional
  # shape. Either counts as their own collection; nothing else does.
  defp collection_matches?(%Account{uri: uri}, %{collection_id: collection_id}) do
    is_binary(uri) and collection_id == uri <> "/followers"
  end

  defp collect(_url, acc, page, _fetch) when page >= @max_pages, do: {:ok, acc}

  defp collect(url, acc, page, fetch) do
    case fetch.(url) do
      {:ok, document} ->
        items = items_of(document)

        case document["next"] do
          next when is_binary(next) -> collect(next, acc ++ items, page + 1, fetch)
          _ -> {:ok, acc ++ items}
        end

      _error ->
        :error
    end
  end

  defp items_of(%{"orderedItems" => items}) when is_list(items), do: strings(items)
  defp items_of(%{"items" => items}) when is_list(items), do: strings(items)
  defp items_of(_document), do: []

  defp strings(items), do: Enum.filter(items, &is_binary/1)

  defp reconcile(%Account{} = account, uris, claimed) do
    expected = uris |> Enum.map(&Accounts.get_account_by_uri/1) |> Enum.filter(&local?/1)

    Enum.each(expected, &settle_outgoing(&1, account))

    # Only when what they sent hashes to what they said it would. Removing a
    # follow on the strength of a half-fetched collection would unfollow people
    # on their behalf.
    if FollowerSync.digest(uris) == claimed do
      remove_unexpected(account, expected)
    end

    :ok
  end

  defp local?(%Account{domain: nil}), do: true
  defp local?(_account), do: false

  # They think this account follows. If it does, nothing to do. If it has a
  # request pending, they have evidently granted it. Otherwise they are
  # delivering to somebody who never asked, so take it back.
  defp settle_outgoing(%Account{} = follower, %Account{} = account) do
    cond do
      Relationships.following?(follower, account) ->
        :ok

      request = Relationships.get_follow_request(follower, account) ->
        Relationships.accept_follow_request(request)

      true ->
        Relationships.withdraw_unknown_follow(follower, account)
    end
  end

  defp remove_unexpected(%Account{} = account, expected) do
    keep = MapSet.new(expected, & &1.id)

    account
    |> Relationships.local_follower_ids()
    |> Enum.reject(&MapSet.member?(keep, &1))
    |> Enum.each(&Relationships.unfollow(&1, account.id))
  end
end
