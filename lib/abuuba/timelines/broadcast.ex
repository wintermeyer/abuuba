defmodule Abuuba.Timelines.Broadcast do
  @moduledoc """
  Rendering a post once and pushing it to everybody watching.

  ## The thing being saved

  A post reaching ten thousand open sockets is one post. Rendering it per
  socket means ten thousand identical passes over the same rows, and most of
  what a rendered status contains is the same for everybody: the words, the
  author, the attachments, the counts. Only a handful of fields differ, and
  only for people who are signed in.

  So the base payload is built once and kept in ETS for a few seconds, and each
  socket patches its own reader's four booleans onto it. The cache is
  deliberately short-lived: it exists to cover the burst of pushes that follow
  one post, not to be a second copy of the database.

  ## Nobody watching, nothing rendered

  Most topics have no subscribers most of the time. A hashtag nobody is
  streaming, a public timeline on a quiet server, an account whose owner is
  asleep. Rendering for those is work with no reader at the end of it, so
  subscriptions are counted and a publish to an empty topic returns without
  touching the database.

  Counted here rather than asked of `Phoenix.PubSub`, which does not offer it:
  `subscribe/1` and `unsubscribe/1` wrap the real ones and keep the tally, and
  a subscriber that dies is noticed by its monitor rather than leaving a count
  that never comes down.

  ## One layer, two consumers

  The LiveView interface and the Mastodon streaming socket read the same
  broadcasts through the same renderer. Two paths would mean two answers to
  "has this person favourited it", and the one nobody is looking at would be
  the wrong one.
  """

  use GenServer

  alias Abuuba.Accounts.Account
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Status
  alias AbuubaWeb.API.Entities
  alias Phoenix.PubSub

  @pubsub Abuuba.PubSub
  @cache :abuuba_broadcast_cache
  @counts :abuuba_broadcast_counts

  # Long enough to cover the pushes that follow one post, short enough that a
  # counter changing underneath is never stale for long. This is a burst
  # buffer, not a cache of the database.
  @ttl_ms 5_000

  ## Starting

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    # Public tables so that a socket patches a payload in its own process
    # rather than queueing behind this one. Writes go through here only for the
    # counts, where two sockets subscribing at once must not lose one.
    :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])

    :ets.new(@counts, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()

    {:ok, %{}}
  end

  ## Subscribing

  @doc """
  Subscribes the calling process and counts it.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic) do
    GenServer.call(__MODULE__, {:subscribe, topic, self()})

    PubSub.subscribe(@pubsub, topic)
  end

  @doc """
  Unsubscribes it.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic) do
    GenServer.call(__MODULE__, {:unsubscribe, topic, self()})

    PubSub.unsubscribe(@pubsub, topic)
  end

  @doc """
  Whether anybody is listening on a topic.
  """
  @spec listening?(String.t()) :: boolean()
  def listening?(topic) do
    case :ets.lookup(@counts, topic) do
      [{^topic, count}] -> count > 0
      [] -> false
    end
  end

  @doc """
  How many processes are listening, for anybody that wants to know.
  """
  @spec listener_count(String.t()) :: non_neg_integer()
  def listener_count(topic) do
    case :ets.lookup(@counts, topic) do
      [{^topic, count}] -> count
      [] -> 0
    end
  end

  ## Publishing

  @doc """
  Sends an event to a topic, unless nobody is there to read it.
  """
  @spec publish(String.t(), String.t(), term()) :: :ok
  def publish(topic, event, payload) do
    if listening?(topic) do
      PubSub.broadcast(@pubsub, topic, {:streaming, event, payload})
    else
      :ok
    end
  end

  @doc """
  Sends a bare message to a topic, whether or not anybody is listening here.

  For control messages rather than stream events: a connection being told to
  close is not something to render, and it must not travel as
  `{:streaming, event, payload}` or a socket would try to draw it.

  Unlike `publish/3` this does not skip an empty topic. That check reads a
  registry of listeners on this node, and a connection being closed may be
  held by another one.
  """
  @spec announce(String.t(), term()) :: :ok
  def announce(topic, message) do
    PubSub.broadcast(@pubsub, topic, message)

    :ok
  end

  ## Rendering

  @doc """
  The payload one viewer should see for a post.

  The expensive half is built once per post and shared; the four fields that
  differ per person are looked up and patched on. A viewer of `nil` needs no
  patch at all, which is every signed-out socket.
  """
  @spec render(Status.t() | integer(), Account.t() | nil) :: map() | nil
  def render(status, viewer \\ nil)

  def render(%Status{} = status, viewer) do
    case base(status) do
      nil -> nil
      payload -> patch(payload, status, viewer)
    end
  end

  def render(status_id, viewer) when is_integer(status_id) do
    case Statuses.get_status_unchecked(status_id) do
      nil -> nil
      status -> render(status, viewer)
    end
  end

  @doc """
  The same post for several viewers at once, with the per-viewer lookups
  batched.

  What a push to many sockets in one place wants: one query for who favourited
  it rather than one per socket.
  """
  @spec render_many(Status.t(), [Account.t() | integer()]) :: %{integer() => map()}
  def render_many(%Status{} = status, viewers) do
    case base(status) do
      nil ->
        %{}

      payload ->
        ids = Enum.map(viewers, &account_id/1)
        state = Statuses.reader_state(status, ids)

        Map.new(ids, fn id -> {id, Map.merge(payload, Map.get(state, id, empty_state()))} end)
    end
  end

  @doc """
  Forgets the cached payload for a post.

  Called when a post changes in a way the base payload would carry: an edit, a
  deletion, a new count. The alternative is a reader seeing the old words for
  as long as the entry lives, which is short but not invisible.
  """
  @spec forget(Status.t() | integer()) :: :ok
  def forget(%Status{id: id}), do: forget(id)

  def forget(status_id) do
    :ets.delete(@cache, status_id)

    :ok
  end

  ## Server

  @impl GenServer
  def handle_call({:subscribe, topic, pid}, _from, state) do
    Process.monitor(pid)
    :ets.update_counter(@counts, topic, {2, 1}, {topic, 0})

    {:reply, :ok, Map.update(state, pid, [topic], &[topic | &1])}
  end

  def handle_call({:unsubscribe, topic, pid}, _from, state) do
    drop(topic)

    {:reply, :ok, Map.update(state, pid, [], &List.delete(&1, topic))}
  end

  @impl GenServer
  # A socket that closed without saying so, which is most of them. Without this
  # the count only ever goes up and every topic looks busy forever.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state |> Map.get(pid, []) |> Enum.each(&drop/1)

    {:noreply, Map.delete(state, pid)}
  end

  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @ttl_ms

    :ets.select_delete(@cache, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])

    schedule_sweep()

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Plumbing

  defp base(%Status{id: id} = status) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@cache, id) do
      [{^id, payload, written_at}] when now - written_at < @ttl_ms ->
        payload

      _ ->
        payload = Entities.status(status, nil)
        :ets.insert(@cache, {id, payload, now})

        payload
    end
  end

  # The base payload was rendered for nobody, so its reader fields are all
  # false. Patching is a merge rather than a rebuild.
  defp patch(payload, _status, nil), do: payload

  defp patch(payload, status, viewer) do
    id = account_id(viewer)

    Map.merge(payload, Map.get(Statuses.reader_state(status, [id]), id, empty_state()))
  end

  defp empty_state do
    %{"favourited" => false, "reblogged" => false, "bookmarked" => false, "pinned" => false}
  end

  defp account_id(%Account{id: id}), do: id
  defp account_id(id) when is_integer(id), do: id

  defp drop(topic) do
    if :ets.update_counter(@counts, topic, {2, -1, 0, 0}, {topic, 0}) == 0 do
      :ets.delete(@counts, topic)
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @ttl_ms)
end
