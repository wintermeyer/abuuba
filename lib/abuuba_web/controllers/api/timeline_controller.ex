defmodule AbuubaWeb.API.TimelineController do
  @moduledoc """
  `/api/v1/timelines`, and the markers that remember where somebody was.

  ## Who may read the public timelines

  An admin setting, because it is a real decision rather than a preference. A
  server that is a private community does not want its federated timeline
  readable by anybody who finds the URL, and a server that is a public square
  does. The three settings are `public`, `authenticated` and `disabled`, and
  the default is `public` because that is what the rest of the network expects
  and what makes an instance discoverable.

  The home timeline is not gated: it needs a token by definition, since there
  is no home without somebody whose home it is.
  """

  use AbuubaWeb, :controller

  alias Abuuba.AsyncRefreshes
  alias Abuuba.Lists
  alias Abuuba.Settings
  alias Abuuba.Timelines
  alias Abuuba.Timelines.Marker
  alias Abuuba.Timelines.RegenerateWorker
  alias AbuubaWeb.API
  alias AbuubaWeb.API.AsyncRefreshHeader
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.API.NestedParams
  alias AbuubaWeb.API.Pagination

  plug AbuubaWeb.Plugs.RequireUser when action in [:home, :list, :get_markers, :put_markers]

  plug AbuubaWeb.Plugs.RequireScopes, ["read:statuses"] when action in [:home, :get_markers]

  # A list timeline is the list's contents as much as it is posts, and that is
  # the scope an app asking for lists already holds.
  plug AbuubaWeb.Plugs.RequireScopes, ["read:lists"] when action in [:list]

  # Public timelines answer a stranger, and a token still changes them: blocks
  # and mutes are applied for whoever is reading.
  plug AbuubaWeb.Plugs.RequireScopes,
       {:when_authenticated, ["read:statuses"]} when action in [:public, :tag, :link]

  plug AbuubaWeb.Plugs.RequireScopes, ["write:statuses"] when action in [:put_markers]

  def home(conn, params) do
    account = current_account(conn)
    statuses = Timelines.home(account, page(params))

    conn
    |> maybe_regenerating(account, statuses)
    |> render_timeline(statuses, account)
  end

  # 206 rather than 200 when there is nothing yet but there ought to be.
  # A client that gets an empty 200 shows "nothing to read"; the partial status
  # tells it to try again shortly, and the header says roughly when. The rebuild
  # is queued here because this request is the first sign anybody is waiting for
  # it.
  defp maybe_regenerating(conn, account, []) do
    if Timelines.regenerating?(account) do
      # The refresh comes first so the job can carry its id, and the rebuild is
      # queued whichever answer came back. Queueing only for the request that
      # created the refresh reads as the tidier rule and is wrong: a job that
      # exhausted its attempts leaves a running row nothing will ever finish,
      # and every later request would then join it and queue nothing, so an
      # empty home feed would stay empty for the row's whole day. Running the
      # work once is the job queue's business, not this row's — see the
      # worker's `unique` option.
      refresh = AsyncRefreshes.start(account, "home_feed", count_results: true)

      RegenerateWorker.enqueue(account.id, refresh_id(refresh))

      conn
      |> put_resp_header("x-feed-regenerating", "true")
      |> AsyncRefreshHeader.put(refresh, retry: 5)
      |> put_status(:partial_content)
    else
      conn
    end
  end

  defp maybe_regenerating(conn, _account, _statuses), do: conn

  defp refresh_id({state, refresh}) when state in [:started, :joined], do: refresh.id
  defp refresh_id(:error), do: nil

  def public(conn, params) do
    with_public_access(conn, fn viewer ->
      statuses = Timelines.public(viewer, page(params))

      render_timeline(conn, statuses, viewer)
    end)
  end

  def tag(conn, %{"hashtag" => hashtag} = params) do
    with_public_access(conn, fn viewer ->
      statuses = Timelines.tag(hashtag, viewer, page(params))

      render_timeline(conn, statuses, viewer)
    end)
  end

  @doc """
  What the people in one list said.
  """
  def list(conn, %{"id" => id} = params) do
    account = current_account(conn)

    case Lists.get(account, API.id_param(%{"id" => id}, "id")) do
      # An empty list and a list that does not exist are different things, and
      # a client shows them differently.
      nil -> API.error(conn, 404, "Record not found")
      list -> render_timeline(conn, Timelines.list(list, account, page(params)), account)
    end
  end

  @doc """
  Posts linking to one article.

  Link cards arrive with their own issue; until there are cards there is
  nothing to group by, so this answers with nothing rather than with an error a
  client would show.
  """
  def link(conn, _params), do: json(conn, [])

  ## Markers

  def get_markers(conn, params) do
    account = current_account(conn)
    wanted = params |> Map.get("timeline", Marker.timelines()) |> NestedParams.list()

    json(
      conn,
      account |> Timelines.markers(wanted) |> Map.new(&{elem(&1, 0), marker(elem(&1, 1))})
    )
  end

  @doc """
  Moves one or more markers.

  A write against a stale version is a 409 rather than a silent overwrite: two
  clients both holding a marker is the ordinary case, and last-write-wins would
  drag somebody's place backwards to whatever the slower device believed.
  """
  def put_markers(conn, params) do
    account = current_account(conn)

    params
    |> Map.take(Marker.timelines())
    |> Enum.reduce_while({:ok, %{}}, fn {timeline, attrs}, {:ok, acc} ->
      case write_marker(account, timeline, attrs) do
        {:ok, marker} -> {:cont, {:ok, Map.put(acc, timeline, marker(marker))}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, written} -> json(conn, written)
      {:error, :conflict} -> API.error(conn, 409, "Conflict during update")
      {:error, _changeset} -> API.error(conn, 422, "Validation failed")
    end
  end

  defp write_marker(account, timeline, attrs) when is_map(attrs) do
    case API.id_param(attrs, "last_read_id") do
      nil -> {:error, :invalid}
      id -> Timelines.put_marker(account, timeline, id, version(attrs))
    end
  end

  defp write_marker(_account, _timeline, _attrs), do: {:error, :invalid}

  defp version(attrs) do
    case Map.get(attrs, "version") do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_version(value)
      _ -> nil
    end
  end

  defp parse_version(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp marker(%Marker{} = marker) do
    %{
      "last_read_id" => API.id(marker.last_read_id),
      "version" => marker.version,
      "updated_at" => DateTime.to_iso8601(marker.updated_at)
    }
  end

  ## Plumbing

  defp render_timeline(conn, statuses, viewer) do
    conn
    |> Pagination.put_link_header(statuses)
    |> json(Entities.statuses(statuses, viewer, filter_context: filter_context(conn)))
  end

  # Which of the reader's filters apply here. The home timeline and a list are
  # "home" to a filter, and everything else public is "public"; the reference
  # implementation draws the same two lines, and a filter written for one is
  # not silently applied to the other.
  defp filter_context(conn) do
    case Phoenix.Controller.action_name(conn) do
      action when action in [:home, :list] -> "home"
      _ -> "public"
    end
  end

  # `disabled` is a 404 rather than a 403: a server that has turned its public
  # timelines off is saying there is nothing here, not that you are unwelcome.
  defp with_public_access(conn, fun) do
    viewer = current_account(conn)

    case Settings.timeline_access() do
      :disabled ->
        API.error(conn, 404, "Record not found")

      :authenticated when is_nil(viewer) ->
        API.error(conn, 422, "This method requires an authenticated user")

      _readable ->
        fun.(viewer)
    end
  end

  defp page(params) do
    params
    |> Pagination.params(default: 20, max: 40)
    |> Map.merge(%{
      local: API.truthy?(params["local"]),
      remote: API.truthy?(params["remote"]),
      only_media: API.truthy?(params["only_media"]),
      any: NestedParams.list(params["any"]),
      all: NestedParams.list(params["all"]),
      none: NestedParams.list(params["none"])
    })
  end
end
