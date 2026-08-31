defmodule AbuubaWeb.Streaming.Subscription do
  @moduledoc """
  What a client may subscribe to, and which topic that means.

  ## One table, because two had already drifted apart

  A WebSocket and an SSE connection are two ways of asking for the same
  streams, and each carried its own copy of the answer: the same
  `timelines_readable?/2` down to its five-line comment, the same
  `account_of/1`, one scope rule spelled twice, and two tables of stream names
  that were no longer the same table. The socket knew `public:media`,
  `public:local:media`, `public:remote:media` and `list`; the SSE side knew
  none of them and spelled two of its own with a slash.

  That last part is what made it worth fixing rather than watching.
  `AbuubaWeb.Streaming.Filter` decides whether a post belongs on a stream by
  matching its name, and ended `belongs_on?(_stream, _status), do: true` --
  so a name it did not recognise let everything through. A client on the SSE
  side asking for `public/local` got every public post, local or not, and one
  asking for a media stream that transport did not know got posts with no
  media in them.

  ## The canonical spelling is the colon one

  `topic_for/3` answers with the name as well as the topic, and both
  transports store what it answers rather than what the client typed. A slash
  is accepted and normalised on the way in, because a client that used it was
  reaching a real stream and should keep reaching one -- it is a spelling, not
  a different thing to subscribe to.
  """

  alias Abuuba.OAuth.Scopes
  alias Abuuba.Settings
  alias Abuuba.Streaming
  alias AbuubaWeb.Streaming.Payload

  # Every stream this server serves. `Filter` is exhaustive over this list, so
  # a name added here without a rule there is a compile-time gap rather than a
  # stream that quietly carries everything.
  @streams ~w(
    user user:notification direct
    public public:local public:remote
    public:media public:local:media public:remote:media
    hashtag hashtag:local
    list
  )

  @doc """
  Every stream name this server answers to.
  """
  @spec streams() :: [String.t()]
  def streams, do: @streams

  @doc """
  The canonical spelling of what a client asked for.

  `public/local` and `hashtag/local` are the two a client may have sent, from
  the days when this endpoint took two path segments.
  """
  @spec normalise(String.t()) :: String.t()
  def normalise(stream) when is_binary(stream), do: String.replace(stream, "/", ":")
  def normalise(stream), do: stream

  @doc """
  The topic one subscription listens on, and the name it is known by.

  `{:ok, name, topic}` where the client may have it, `:error` where the stream
  does not exist or needs an account the connection has not got. The name
  comes back because it is what `AbuubaWeb.Streaming.Filter` is keyed on, and
  a transport storing the client's spelling instead is how the two came apart.
  """
  @spec topic_for(String.t(), map(), map()) :: {:ok, String.t(), String.t()} | :error
  def topic_for(stream, params, state) do
    name = normalise(stream)

    case topic(name, params, state) do
      {:ok, topic} -> {:ok, name, topic}
      :error -> :error
    end
  end

  @doc """
  Whether this connection may listen to this stream at all.

  Two questions. The scope one is the token's: a stream that carries
  somebody's own posts or notifications needs a token that says so. The other
  is the server's -- an admin who closes the timelines has said strangers do
  not read this server, and a socket is the third door onto them after the API
  and the pages. Matched on the name rather than a list, so a public stream
  added later is covered without anybody remembering to come back here.
  """
  @spec allowed?(map(), String.t()) :: boolean()
  def allowed?(state, stream) do
    name = normalise(stream)

    timelines_readable?(state, name) and scope_allows?(state, name)
  end

  defp timelines_readable?(state, stream) do
    if String.starts_with?(stream, "public") or String.starts_with?(stream, "hashtag") do
      Settings.public_timelines_readable?(state.account)
    else
      true
    end
  end

  defp scope_allows?(state, stream) do
    case Payload.required_scope(stream) do
      nil -> true
      required -> state.account != nil and Scopes.covers_all?(state.scopes, [required])
    end
  end

  defp topic(stream, _params, %{account: nil})
       when stream in ~w(user user:notification direct list),
       do: :error

  defp topic(stream, _params, state) when stream in ~w(user user:notification direct list),
    do: {:ok, Streaming.account_topic(state.account)}

  defp topic(stream, _params, _state) when stream in ~w(public public:media),
    do: {:ok, Streaming.public_topic()}

  defp topic(stream, _params, _state) when stream in ~w(public:local public:local:media),
    do: {:ok, Streaming.public_topic(local: true)}

  defp topic(stream, _params, _state) when stream in ~w(public:remote public:remote:media),
    do: {:ok, Streaming.public_topic(remote: true)}

  defp topic(stream, params, _state) when stream in ~w(hashtag hashtag:local) do
    case Map.get(params, "tag") do
      tag when is_binary(tag) and tag != "" -> {:ok, Streaming.hashtag_topic(tag)}
      _ -> :error
    end
  end

  defp topic(_stream, _params, _state), do: :error
end
