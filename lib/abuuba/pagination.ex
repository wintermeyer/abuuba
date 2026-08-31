defmodule Abuuba.Pagination do
  @moduledoc """
  The one rule of cursor paging, in one place.

  `max_id` and `since_id` window a list that is read newest-first. `min_id`
  is different: it is a client saying "I have everything up to here", and the
  page it wants starts just past that point — the query must read *ascending*
  from the cursor and the page is then flipped so the client still receives
  newest-first. Six paginators used to treat `min_id` as another `since_id`
  and answered with the newest page instead of the missing one, which strands
  a client that is filling a gap.

  A query paginates itself with its own bindings (the cursor column sits in a
  different position everywhere) and asks this module which direction to read
  (`direction/1`) and how to hand the rows back (`reading_order/2`).
  """

  @doc """
  Which way the query should read: `:asc` for a `min_id` ask, else `:desc`.

  An explicit `:order` in the page wins, which is what `AbuubaWeb.API.Pagination`
  sets when it parses request parameters.
  """
  @spec direction(map()) :: :asc | :desc
  def direction(%{order: order}) when order in [:asc, :desc], do: order
  def direction(page), do: if(Map.get(page, :min_id), do: :asc, else: :desc)

  @doc """
  Rows in the order a client reads: newest first, whichever way the query ran.
  """
  @spec reading_order([row], map()) :: [row] when row: var
  def reading_order(rows, page) do
    if direction(page) == :asc, do: Enum.reverse(rows), else: rows
  end

  @doc """
  Windows, orders and limits a query by its `id`, for the ordinary case.

  Only for a query whose cursor is the `id` of its first binding, which is
  every list where the row's own id is what a client pages by. Anything
  windowing a joined column or a denormalised cursor still does it by hand
  with `direction/1`; this exists so that the many places which do not have
  that problem stop writing the same four clauses each.

  Both bounds are exclusive, matching the reference implementation: a client
  that passes back the id it last saw must not receive it again, or it pages
  forever.

  A client sending `min_id` and `since_id` together gets the `min_id`
  behaviour and the other is ignored, which is what the reference does --
  `Paginable.to_a_paginated_by_id` branches on `min_id` being present and
  never reads `since_id` in that branch. `min_id` names the gap being filled
  and a second lower bound would cut a hole in it.

  This function used to resolve the pair the other way round while
  `direction/1` two functions up flipped to `:asc` on `min_id`, so a client
  sending both got an ascending page from a `since_id` bound -- neither of the
  two behaviours it could have asked for. Three contexts had grown their own
  copy with the right order, which is how the disagreement was found.
  """
  @spec window(Ecto.Queryable.t(), map()) :: Ecto.Query.t()
  def window(query, page) do
    import Ecto.Query

    query
    |> then(fn q ->
      case Map.get(page, :max_id) do
        nil -> q
        max_id -> where(q, [x], x.id < ^max_id)
      end
    end)
    |> then(fn q ->
      case Map.get(page, :min_id) || Map.get(page, :since_id) do
        nil -> q
        after_id -> where(q, [x], x.id > ^after_id)
      end
    end)
    |> order_by([x], [{^direction(page), x.id}])
    |> limit(^Map.get(page, :limit, 20))
  end
end
