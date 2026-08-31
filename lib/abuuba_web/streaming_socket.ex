defmodule AbuubaWeb.StreamingSocket do
  @moduledoc """
  The WebSocket half of the streaming API.

  Not a Phoenix Channel. The client API's streaming protocol predates this
  server and every app was written against it: a bare socket carrying JSON
  objects of the shape `{"event": ..., "payload": ..., "stream": [...]}`, with
  subscription messages of the shape `{"type": "subscribe", "stream": ...}`.
  A channel's own envelope is a different protocol wearing the same transport,
  and no existing client speaks it.

  ## Where the token comes from

  Three places, because three are in use. A browser cannot set headers on a
  WebSocket, so it puts the token in the query string or smuggles it through
  `Sec-WebSocket-Protocol`; everything else sends a normal `Authorization`
  header. Refusing any one of them would break a class of client for no gain.

  ## Filtering happens here, not at publish time

  A post arrives once per topic and this process decides whether its own reader
  may see it. The answer differs per person, so deciding centrally would mean
  one message per subscriber and the visibility rules written a second time in
  the publisher.
  """

  @behaviour WebSock

  alias Abuuba.Accounts
  alias Abuuba.OAuth
  alias Abuuba.OAuth.Scopes
  alias Abuuba.Streaming
  alias AbuubaWeb.Streaming.Filter
  alias AbuubaWeb.Streaming.Subscription

  @doc """
  Builds the socket's state from the request that is about to be upgraded.

  Done from the `conn` rather than from Phoenix's socket macro, because that
  macro cannot expose the `Authorization` header and a native client sends its
  token there.
  """
  @spec connect(Plug.Conn.t()) :: map()
  def connect(conn) do
    token = token_from(conn)

    case OAuth.get_token(token) do
      nil ->
        # A stream with nobody behind it can still read the public timelines,
        # which is what an anonymous viewer of a public page is doing.
        %{
          account: nil,
          scopes: [],
          topics: MapSet.new(),
          params: conn.query_params,
          token_id: nil
        }

      access_token ->
        %{
          account: account_of(access_token),
          scopes: Scopes.parse!(access_token.scopes),
          topics: MapSet.new(),
          params: conn.query_params,
          token_id: access_token.id
        }
    end
  end

  @impl WebSock
  def init(state) do
    # The token and the announcements, in `Abuuba.Streaming` because the other
    # transport needs exactly the same two and kept not having them.
    Streaming.subscribe_connection(state)

    # A stream named on the connect URL is subscribed straight away, which is
    # what every client does rather than connecting and then subscribing.
    case Map.get(state.params, "stream") do
      nil -> {:ok, state}
      stream -> {:ok, subscribe(state, stream, state.params)}
    end
  end

  @impl WebSock
  def handle_in({text, _opts}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "subscribe", "stream" => stream} = message} ->
        {:ok, subscribe(state, stream, message)}

      {:ok, %{"type" => "unsubscribe", "stream" => stream} = message} ->
        {:ok, unsubscribe(state, stream, message)}

      _ ->
        {:ok, state}
    end
  end

  @impl WebSock
  # Closed rather than answered. There is nothing to tell a client whose token
  # has been taken away, and leaving the socket open to say so would be the
  # bug this exists to fix.
  def handle_info({:streaming, :revoked}, state), do: {:stop, :normal, state}

  def handle_info({:streaming, event, payload}, state) do
    case Filter.for_viewer(event, payload, state) do
      :skip -> {:ok, state}
      {:ok, frame} -> {:push, {:text, frame}, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, _state), do: :ok

  ## Subscription

  defp subscribe(state, stream, params) do
    with true <- Subscription.allowed?(state, stream),
         {:ok, name, topic} <- Subscription.topic_for(stream, params, state) do
      Streaming.subscribe(topic)

      # The name `Subscription` answers with, not the one the client typed:
      # `AbuubaWeb.Streaming.Filter` is keyed on it.
      %{state | topics: MapSet.put(state.topics, {name, topic})}
    else
      _ -> state
    end
  end

  defp unsubscribe(state, stream, params) do
    case Subscription.topic_for(stream, params, state) do
      {:ok, name, topic} ->
        Streaming.unsubscribe(topic)

        %{state | topics: MapSet.delete(state.topics, {name, topic})}

      _ ->
        state
    end
  end

  ## Token

  # Header, query string, or the subprotocol. A browser cannot set headers on a
  # WebSocket, so it uses one of the other two; refusing either would break
  # every web client for no gain.
  defp token_from(conn) do
    header_token(conn) || conn.query_params["access_token"] || protocol_token(conn)
  end

  defp header_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      ["bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end

  # A browser cannot set headers on a WebSocket, so it smuggles the token
  # through the subprotocol list. Refusing that would break every web client.
  defp protocol_token(conn) do
    case Plug.Conn.get_req_header(conn, "sec-websocket-protocol") do
      [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
      _ -> nil
    end
  end

  defp account_of(%{user: %{account_id: account_id}}), do: Accounts.get_account(account_id)
  defp account_of(_token), do: nil
end
