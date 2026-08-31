defmodule AbuubaWeb.API.StreamingController do
  @moduledoc """
  The server-sent-events half of the streaming API, and the health check.

  SSE exists beside the WebSocket because it is one-way and every proxy already
  understands it: a client that only reads and never sends has nothing to gain
  from a duplex connection, and a great many deployments sit behind something
  that mishandles WebSocket upgrades.

  ## The heartbeat is not decoration

  A comment line every fifteen seconds. Without it a proxy that has not seen
  bytes on a connection for a while closes it, and the client discovers the
  stream is dead only when it notices it has heard nothing for an hour.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts
  alias Abuuba.OAuth
  alias Abuuba.OAuth.Scopes
  alias Abuuba.Streaming
  alias AbuubaWeb.Streaming.Filter
  alias AbuubaWeb.Streaming.Subscription

  @heartbeat_ms 15_000

  @doc """
  Upgrades a request to the streaming WebSocket.

  Done here rather than through Phoenix's socket macro, because that macro
  cannot hand the socket the `Authorization` header and a native client sends
  its token there.

  A request that is not an upgrade is answered rather than raised at.
  `WebSockAdapter.upgrade/4` raises on one that is missing the headers, which
  turned every stray GET here into a 500 — a health checker, a crawler, a
  pasted URL, and a client whose proxy stripped `Upgrade`, that last one being
  somebody else's misconfiguration reported as a fault here.

  404 because that is what the reference implementation answers: its upgrades
  are handled on the `upgrade` event, so an ordinary GET matches no route and
  falls through to a not-found.
  """
  def socket(conn, _params) do
    conn = fetch_query_params(conn)

    if websocket_upgrade?(conn) do
      conn
      |> WebSockAdapter.upgrade(
        AbuubaWeb.StreamingSocket,
        AbuubaWeb.StreamingSocket.connect(conn),
        []
      )
      |> halt()
    else
      AbuubaWeb.API.error(conn, 404, "Not found")
    end
  end

  # The two headers RFC 6455 requires. Asked here rather than caught afterwards,
  # because a rescue would also swallow a genuine failure part-way through an
  # upgrade and report it as "not a WebSocket request".
  #
  # Host is not among them, although WebSockAdapter wants one: HTTP/1.1 makes
  # it mandatory and Bandit refuses a request without it before anything here
  # runs. Checking it as a header as well only made this disagree with itself
  # under Plug.Test, which carries the host on the conn instead.
  defp websocket_upgrade?(conn) do
    header_has?(conn, "connection", "upgrade") and header_has?(conn, "upgrade", "websocket")
  end

  defp header_has?(conn, header, value) do
    conn
    |> get_req_header(header)
    |> Enum.any?(&(&1 |> String.downcase() |> String.contains?(value)))
  end

  @doc """
  Whether streaming is working, which is what a load balancer asks.
  """
  def health(conn, _params), do: text(conn, "OK")

  @doc """
  One stream, as server-sent events.
  """
  def stream(conn, %{"stream" => stream} = params) do
    state = connect_state(conn, params)

    case Subscription.topic_for(stream, params, state) do
      {:ok, name, topic} ->
        if Subscription.allowed?(state, stream) do
          Streaming.subscribe(topic)

          # The token and the announcements, shared with the websocket so a
          # fifth thing cannot reach one transport and not the other.
          Streaming.subscribe_connection(state)

          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> send_chunked(200)
          |> loop(%{state | topics: MapSet.put(state.topics, {name, topic})})
        else
          AbuubaWeb.API.error(conn, 401, "This method requires an authenticated user")
        end

      :error ->
        AbuubaWeb.API.error(conn, 404, "Record not found")
    end
  end

  defp loop(conn, state) do
    receive do
      # Closed rather than answered, the same as the websocket half. There is
      # nothing to tell a client whose token has been taken away, and leaving
      # the stream open to say so would be the bug this exists to fix.
      {:streaming, :revoked} ->
        conn

      {:streaming, event, payload} ->
        case Filter.for_viewer(event, payload, state) do
          {:ok, frame} -> push(conn, event, frame, state)
          :skip -> loop(conn, state)
        end
    after
      # A proxy that has seen no bytes closes the connection, and the client
      # then discovers the stream is dead only when it notices an hour of
      # silence.
      @heartbeat_ms ->
        case chunk(conn, ":thump\n\n") do
          {:ok, conn} -> loop(conn, state)
          {:error, :closed} -> conn
        end
    end
  end

  defp push(conn, event, frame, state) do
    payload = frame |> Jason.decode!() |> Map.get("payload")

    case chunk(conn, "event: #{event}\ndata: #{payload}\n\n") do
      {:ok, conn} -> loop(conn, state)
      {:error, :closed} -> conn
    end
  end

  defp connect_state(conn, params) do
    token = bearer(conn) || params["access_token"]

    case OAuth.get_token(token) do
      nil ->
        %{account: nil, scopes: [], topics: MapSet.new(), token_id: nil}

      access_token ->
        %{
          account: account_of(access_token),
          scopes: Scopes.parse!(access_token.scopes),
          topics: MapSet.new(),
          token_id: access_token.id
        }
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      ["bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end

  defp account_of(%{user: %{account_id: account_id}}), do: Accounts.get_account(account_id)
  defp account_of(_token), do: nil
end
