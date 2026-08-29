defmodule AbuubaWeb.API.Pagination do
  @moduledoc """
  How a client walks a timeline, and the `Link` header that tells it how.

  Cursors rather than offsets, because a timeline moves under the reader. With
  `?page=2`, a post arriving between two requests pushes everything down and
  the reader sees the last item of page one again at the top of page two. With
  an id cursor, "everything older than this one" means the same thing however
  much has arrived since.

  ## Three cursors, two windows

  `max_id` and `since_id` both describe a **descending** window: newest first,
  bounded above by `max_id` and stopping at `since_id`. `min_id` describes an
  **ascending** one: oldest first from just after `min_id`, which is how a
  client catches up on what it missed rather than re-reading the top.

  That distinction is the whole reason `min_id` exists as well as `since_id`.
  With `since_id` and a gap of five hundred posts, a client asking for twenty
  gets the twenty *newest* and never sees the other four hundred and eighty.
  With `min_id` it gets the twenty *oldest* it is missing and can walk forward.

  ## No links on an empty page

  A `Link` header with a `next` pointing at nothing tells a client to keep
  asking. On an empty result set the header is omitted entirely, which is what
  ends a client's paging loop.
  """

  import Plug.Conn

  alias Abuuba.Federation.URIs
  alias AbuubaWeb.API

  @doc """
  The cursors and limit a request carries.

  `:order` is `:desc` for the ordinary case and `:asc` where `min_id` was
  given, and it is the caller's job to honour it: a query that ignores it
  returns the newest rows for a request that asked for the oldest missing ones.
  """
  @spec params(map(), keyword()) :: %{
          max_id: integer() | nil,
          since_id: integer() | nil,
          min_id: integer() | nil,
          limit: pos_integer(),
          order: :asc | :desc
        }
  def params(params, opts \\ []) do
    min_id = API.id_param(params, "min_id")

    %{
      max_id: API.id_param(params, "max_id"),
      since_id: API.id_param(params, "since_id"),
      min_id: min_id,
      limit: API.limit(params, Keyword.get(opts, :default, 20), Keyword.get(opts, :max)),
      order: if(min_id, do: :asc, else: :desc)
    }
  end

  @doc """
  Puts the `Link` header for a page of records.

  `records` must already be in the order they will be rendered, newest first.
  The cursors come off the ends of the page rather than out of the request, so
  a client that asked for something odd still gets links that walk the data it
  was actually given.
  """
  @spec put_link_header(Plug.Conn.t(), [struct()] | [map()], keyword()) :: Plug.Conn.t()
  def put_link_header(conn, records, opts \\ [])
  def put_link_header(conn, [], _opts), do: conn

  def put_link_header(conn, records, opts) do
    url = Keyword.get_lazy(opts, :url, fn -> page_url(conn) end)
    query = Keyword.get_lazy(opts, :query, fn -> fetch_query_params(conn).query_params end)

    links =
      [
        {"next", link(url, query, "max_id", cursor_of(List.last(records), opts))},
        {"prev", link(url, query, "min_id", cursor_of(List.first(records), opts))}
      ]
      |> Enum.map_join(", ", fn {rel, target} -> ~s(<#{target}>; rel="#{rel}") end)

    put_resp_header(conn, "link", links)
  end

  # Older than the oldest on this page, newer than the newest. The cursor
  # parameters are mutually exclusive, so whichever one the request came in
  # with is dropped rather than added to.
  defp link(url, query, cursor, id) do
    query =
      query
      |> Map.drop(["max_id", "min_id", "since_id"])
      |> Map.put(cursor, API.id(id))
      |> Enum.flat_map(&pairs/1)
      |> URI.encode_query()

    "#{url}?#{query}"
  end

  # A repeated parameter arrives as a list and a numbered one as a map, and
  # `URI.encode_query/1` takes neither. Written back out in the bracket
  # notation they came in as, because that is what makes the link a client
  # follows carry the same filters the request did: `any=a&any=b` encodes
  # without complaint and decodes to `b` alone, so the second page of a
  # hashtag timeline quietly forgot a tag. The map went out worse -- the page
  # was built and then raised on the way out, a 500 with a rendered body
  # behind it.
  defp pairs({key, values}) when is_list(values),
    do: Enum.map(values, &{"#{key}[]", to_string(&1)})

  defp pairs({key, nested}) when is_map(nested) and not is_struct(nested),
    do: Enum.flat_map(nested, fn {inner, value} -> pairs({"#{key}[#{inner}]", value}) end)

  defp pairs({key, value}), do: [{key, to_string(value)}]

  # A row's own id by default, because that is what almost everything paginates
  # by. `:cursor` is for the ones that do not: a conversation is ordered by
  # when it last moved, so its cursor is the last status rather than the row.
  defp cursor_of(record, opts) do
    case Keyword.get(opts, :cursor) do
      nil -> record_id(record)
      fun -> fun.(record)
    end
  end

  defp record_id(%{id: id}), do: id

  # From the configured host rather than the request's. A request arriving on
  # some other hostname would otherwise be answered with links under that name,
  # and a client following them would leave the server it was talking to.
  defp page_url(conn), do: URIs.base_url() <> conn.request_path
end
