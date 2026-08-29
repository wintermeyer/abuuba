defmodule Abuuba.Cache do
  @moduledoc """
  A small read-through cache for values that are asked for on every request
  and change on admin action: instance settings, the custom emoji list, the
  instance actor's signing key, the usage numbers.

  ## What it is and is not

  An ETS table with a time-to-live per entry and explicit invalidation.
  Invalidation broadcasts over PubSub so every node in a cluster drops the
  entry, and the TTL is the backstop for a missed broadcast: nothing here may
  be stale for longer than its TTL even if a node never hears the write.

  Nothing security-relevant belongs in here. A block list read through a
  cache is a block that stops working when the cache misbehaves, which is why
  `Abuuba.Moderation.Signup` deliberately reads its tables per request.

  One window is accepted rather than closed: a reader that computed a value
  before a write can insert it after the write's invalidation, so a node can
  serve the old value until the TTL lapses. That is why every TTL here is
  short, and why anything that cannot tolerate a stale minute does not belong
  in this cache.

  ## Failing towards the truth

  Every miss — cold table, expired entry, cache process dead — falls through
  to computing the value from the database. The cache can only ever serve a
  value the database served first, and switching it off (`config :abuuba,
  cache_enabled: false`, which the test environment does) leaves every caller
  correct, just slower.
  """

  use GenServer

  @table __MODULE__
  @topic "abuuba:cache"

  @doc """
  The cached value under `key`, or `fun.()` computed and kept for `ttl_ms`.
  """
  @spec fetch(term(), pos_integer(), (-> value)) :: value when value: var
  def fetch(key, ttl_ms, fun) do
    if enabled?() do
      lookup(key, fun, ttl_ms)
    else
      fun.()
    end
  end

  @doc """
  Drops `key` here and on every other node.

  Call it from the write path of whatever the key caches; the TTL is the
  backstop, not the mechanism.
  """
  @spec invalidate(term()) :: :ok
  def invalidate(key) do
    # Deleted here synchronously, so a read on this node right after the write
    # already misses; the broadcast covers the other nodes, and reaches this
    # one again harmlessly.
    try do
      :ets.delete(@table, key)
    rescue
      ArgumentError -> :ok
    end

    Phoenix.PubSub.broadcast(Abuuba.PubSub, @topic, {:invalidate, key})

    :ok
  end

  ## GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Abuuba.PubSub, @topic)

    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:invalidate, key}, state) do
    :ets.delete(@table, key)

    {:noreply, state}
  end

  ## Reading

  defp lookup(key, fun, ttl_ms) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        value

      _missing_or_expired ->
        value = fun.()

        # A `nil` is not kept. It is the answer for something that does not
        # exist yet rather than something that is, and keeping it turns "not
        # ready a moment ago" into "not there for the next five minutes".
        #
        # The instance signing key is read through here and is nil for the
        # instant between the actor existing and its keypair existing. Keeping
        # that would send every outbound request unsigned for the whole TTL,
        # which is invisible from this side: deliveries keep leaving and every
        # peer refuses them.
        #
        # The cost is recomputing a miss until there is something to keep,
        # which is the cheap direction to be wrong in.
        if not is_nil(value), do: :ets.insert(@table, {key, value, now + ttl_ms})

        value
    end
  rescue
    # The table is gone — the cache process died and has not restarted yet.
    # The value still exists in the database, so serve it from there.
    ArgumentError -> fun.()
  end

  defp enabled? do
    Application.get_env(:abuuba, :cache_enabled, true)
  end
end
