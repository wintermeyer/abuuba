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
  alias Abuuba.Settings
  alias Abuuba.Streaming
  alias AbuubaWeb.Streaming.Filter
  alias AbuubaWeb.Streaming.Payload

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
    with :ok <- check_scope(state, stream),
         true <- timelines_readable?(state, stream),
         {:ok, topic} <- topic_for(stream, params, state) do
      Streaming.subscribe(topic)

      %{state | topics: MapSet.put(state.topics, {stream, topic})}
    else
      _ -> state
    end
  end

  defp unsubscribe(state, stream, params) do
    case topic_for(stream, params, state) do
      {:ok, topic} ->
        Streaming.unsubscribe(topic)

        %{state | topics: MapSet.delete(state.topics, {stream, topic})}

      _ ->
        state
    end
  end

  # A public stream needs nothing; anything naming a person needs a token that
  # was granted the right to read that thing. Checked per subscription rather
  # than at connect, because one socket carries several streams.
  # An admin who closes the timelines has said strangers do not read this
  # server. The API refuses them and the front page refuses them; this is the
  # third door, and it was answering. Matched on the name rather than on a
  # list, so a public stream added later is covered without anybody
  # remembering to add it here.
  defp timelines_readable?(state, stream) do
    if String.starts_with?(stream, "public") or String.starts_with?(stream, "hashtag") do
      Settings.public_timelines_readable?(state.account)
    else
      true
    end
  end

  defp check_scope(state, stream) do
    required = Payload.required_scope(stream)

    cond do
      is_nil(required) -> :ok
      is_nil(state.account) -> :error
      Scopes.covers_all?(state.scopes, [required]) -> :ok
      true -> :error
    end
  end

  defp topic_for("user", _params, %{account: nil}), do: :error
  defp topic_for("user", _params, state), do: {:ok, Streaming.account_topic(state.account)}

  defp topic_for("user:notification", _params, %{account: nil}), do: :error

  defp topic_for("user:notification", _params, state),
    do: {:ok, Streaming.account_topic(state.account)}

  defp topic_for("direct", _params, %{account: nil}), do: :error
  defp topic_for("direct", _params, state), do: {:ok, Streaming.account_topic(state.account)}

  defp topic_for("public", _params, _state), do: {:ok, Streaming.public_topic()}
  defp topic_for("public:local", _params, _state), do: {:ok, Streaming.public_topic(local: true)}

  defp topic_for("public:remote", _params, _state),
    do: {:ok, Streaming.public_topic(remote: true)}

  defp topic_for("public:media", _params, _state), do: {:ok, Streaming.public_topic()}

  defp topic_for("public:local:media", _params, _state),
    do: {:ok, Streaming.public_topic(local: true)}

  defp topic_for("public:remote:media", _params, _state),
    do: {:ok, Streaming.public_topic(remote: true)}

  defp topic_for(hashtag, params, _state) when hashtag in ["hashtag", "hashtag:local"] do
    case Map.get(params, "tag") do
      tag when is_binary(tag) and tag != "" -> {:ok, Streaming.hashtag_topic(tag)}
      _ -> :error
    end
  end

  defp topic_for("list", _params, %{account: nil}), do: :error
  defp topic_for("list", _params, state), do: {:ok, Streaming.account_topic(state.account)}
  defp topic_for(_stream, _params, _state), do: :error

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
