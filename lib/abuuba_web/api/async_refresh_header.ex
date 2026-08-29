defmodule AbuubaWeb.API.AsyncRefreshHeader do
  @moduledoc """
  The `Mastodon-Async-Refresh` header, which tells a client that the answer it
  just got is not the whole answer yet.

      Mastodon-Async-Refresh: id="1234", retry=3, result_count=0

  A client that does not know the header sees an ordinary response and shows
  what arrived, which is why the endpoint answers rather than waiting.

  Only sent while the work is running. A header naming a refresh that is
  already finished sends a client off to poll something that will never change.
  """

  import Plug.Conn

  alias Abuuba.AsyncRefreshes.AsyncRefresh
  alias AbuubaWeb.API

  @header "mastodon-async-refresh"

  @doc """
  Names a running refresh in the response.

  `retry` is the seconds a client should wait before asking again.
  """
  @spec put(
          Plug.Conn.t(),
          AsyncRefresh.t() | {:started | :joined, AsyncRefresh.t()} | :error | nil,
          keyword()
        ) :: Plug.Conn.t()
  def put(conn, refresh, opts \\ [])
  def put(conn, nil, _opts), do: conn
  def put(conn, :error, _opts), do: conn

  # Takes `AsyncRefreshes.start/3` as it comes, so a caller does not have to
  # unwrap a result whose two halves it treats identically here.
  def put(conn, {started_or_joined, refresh}, opts)
      when started_or_joined in [:started, :joined],
      do: put(conn, refresh, opts)

  def put(conn, %AsyncRefresh{} = refresh, opts) do
    if AsyncRefresh.running?(refresh) do
      put_resp_header(conn, @header, value(refresh, Keyword.get(opts, :retry, 3)))
    else
      conn
    end
  end

  defp value(refresh, retry) do
    parts = ["id=\"#{API.id(refresh.id)}\"", "retry=#{retry}"]

    # Omitted rather than zeroed where the refresh does not count: "none yet"
    # and "this is not the sort of work that has results" are different things
    # to a client deciding whether to reload.
    parts =
      if is_nil(refresh.result_count),
        do: parts,
        else: parts ++ ["result_count=#{refresh.result_count}"]

    Enum.join(parts, ", ")
  end
end
