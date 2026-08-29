defmodule AbuubaWeb.API.SearchController do
  @moduledoc """
  `/api/v2/search`.

  Three kinds of answer from one query: accounts, hashtags and posts. A person
  types one thing into one box and does not know which of the three they are
  looking for.

  ## A URL is not a search

  Pasting a link to a post or a profile is how somebody brings something from
  another server into view, and treating it as words to match would search for
  the literal text of the URL and find nothing. So a query that parses as a URL
  short-circuits to resolving it.

  ## Why `offset` and `resolve` need a token

  Both are how a search box becomes a crawler. `offset` walks the whole corpus
  a page at a time, and `resolve` makes this server go and fetch whatever
  address it is handed, which is somebody else's bandwidth being spent by an
  anonymous stranger. Neither is refused to a signed-in person, whose requests
  are counted against their own account.
  """

  use AbuubaWeb, :controller

  # Search answers a stranger with no token, so the scope is a condition on the
  # token rather than on the request: an app that only asked to write posts has
  # no business searching, and somebody with no app at all is not the case this
  # is about.
  plug AbuubaWeb.Plugs.RequireScopes,
       {:when_authenticated, ["read:search"]} when action in [:search]

  alias Abuuba.Accounts
  alias Abuuba.Federation.ResolveActor
  alias Abuuba.Federation.ResolveStatus
  alias Abuuba.Search
  alias Abuuba.Statuses
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities

  def search(conn, params) do
    viewer = current_account(conn)
    query = String.trim(to_string(params["q"] || ""))

    cond do
      query == "" ->
        json(conn, empty())

      needs_account?(params) and is_nil(viewer) ->
        API.error(conn, 401, "This method requires an authenticated user")

      # An address always takes this path, because somebody who pasted one
      # meant that thing and not a text search for it. A handle takes it only
      # when the caller asked to resolve: without that it is an ordinary search
      # over what this server already holds, which is what `resolve=false`
      # means.
      url?(query) or (truthy?(params["resolve"]) and ResolveActor.resolvable?(query)) ->
        json(conn, resolve(query, viewer, truthy?(params["resolve"])))

      true ->
        json(conn, run(query, viewer, params))
    end
  end

  defp run(query, viewer, params) do
    type = params["type"]
    limit = API.limit(params, 20, 40)
    offset = offset(params)

    # The three the endpoint used to take and drop. A wrong list looks like an
    # answer, which is worse than a refusal: somebody searching within one
    # profile was given everybody's posts and no reason to doubt them.
    account_id = API.id_param(params, "account_id")
    followed_by = if truthy?(params["following"]) and viewer, do: viewer.id
    exclude_unreviewed = truthy?(params["exclude_unreviewed"])

    %{
      "accounts" =>
        if(type in [nil, "accounts"],
          do:
            query
            |> Search.accounts(viewer, limit: limit, followed_by: followed_by)
            |> Entities.accounts(viewer),
          else: []
        ),
      "statuses" =>
        if(type in [nil, "statuses"],
          do:
            query
            |> Search.statuses(viewer, limit: limit, offset: offset, account_id: account_id)
            |> Entities.statuses(viewer),
          else: []
        ),
      "hashtags" =>
        if(type in [nil, "hashtags"],
          do:
            query
            |> Search.tags(viewer, limit: limit, exclude_unreviewed: exclude_unreviewed)
            |> Enum.map(&Entities.tag/1),
          else: []
        )
    }
  end

  # An address is fetched only when the caller asked for it. Following every
  # URL anybody pastes would make this server fetch whatever it is handed,
  # which is both an SSRF surface and a way to spend somebody else's bandwidth.
  defp resolve(url, viewer, true) do
    # `resolve_query/2` rather than `resolve/1`, because what somebody typed is
    # as often a handle as an address, and a handle has to be asked about at
    # the server it names. Pushing one through the address path answered "no
    # such person" about somebody plainly there.
    case ResolveActor.resolve_query(url) do
      {:ok, account} ->
        %{empty() | "accounts" => [Entities.account(account, viewer)]}

      _ ->
        case ResolveStatus.resolve(url) do
          {:ok, status} -> %{empty() | "statuses" => Entities.statuses([status], viewer)}
          _ -> empty()
        end
    end
  end

  defp resolve(url, viewer, false) do
    # Not fetched, but something we already hold under that address is still
    # the answer somebody pasting it wanted.
    account = Accounts.get_account_by_uri(url)
    status = Statuses.get_status_unchecked_by_uri(url)

    %{
      empty()
      | "accounts" => if(account, do: [Entities.account(account, viewer)], else: []),
        "statuses" => if(status, do: Entities.statuses([status], viewer), else: [])
    }
  end

  defp empty, do: %{"accounts" => [], "statuses" => [], "hashtags" => []}

  defp needs_account?(params) do
    truthy?(params["resolve"]) or offset(params) > 0
  end

  defp url?(query),
    do: match?(%URI{scheme: scheme} when scheme in ["http", "https"], URI.parse(query))

  defp offset(params) do
    case Integer.parse(to_string(Map.get(params, "offset", "0"))) do
      {number, _rest} when number > 0 -> number
      _ -> 0
    end
  end

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
