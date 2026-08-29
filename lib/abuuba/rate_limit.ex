defmodule Abuuba.RateLimit do
  @moduledoc """
  A fixed-window counter, for the endpoints worth slowing an attacker down on.

  Kept in ETS in the one node's memory. That is a deliberate limit rather than
  an oversight: a shared store would be a second thing to run, and this project
  is trying not to have one. Across several nodes each keeps its own count, so
  the effective limit is the configured one times the node count. For login
  attempts and signups that is fine, because the point is to make guessing
  expensive rather than to enforce an exact quota.

  Windows are fixed rather than sliding, which means up to twice the limit can
  land across a window boundary. Same reasoning: cheap, and close enough for
  what it defends.

  ## Testing

  The window is read from config, so a test can shrink it rather than sleep.
  Nothing here reads the wall clock except through `System.monotonic_time/1`.
  """

  use GenServer

  @table __MODULE__

  @typedoc "What a client is told about the bucket it just counted against."
  @type state :: %{limit: pos_integer(), remaining: non_neg_integer(), reset_at: DateTime.t()}

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

    {:ok, %{}}
  end

  @doc """
  Counts one attempt against `key` and says whether it is still allowed.

  Returns `{:ok, remaining}` or `{:error, :rate_limited}`.

      RateLimit.hit("login:" <> ip, limit: 10, window_ms: 60_000)
  """
  @spec hit(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, :rate_limited}
  def hit(key, opts) do
    case take(key, opts) do
      {:ok, %{remaining: remaining}} -> {:ok, remaining}
      {:error, _state} -> {:error, :rate_limited}
    end
  end

  @doc """
  The same, with everything a caller has to tell the client.

  `X-RateLimit-Reset` is an instant, so the window has to be one a wall clock
  can name. Windows are therefore aligned to the epoch rather than counted from
  whenever the node started: every client sharing a bucket is told the same
  reset, and it is a time they can actually wait for.
  """
  @spec take(String.t(), keyword()) ::
          {:ok, state()} | {:error, state()}
  def take(key, opts) do
    limit = Keyword.fetch!(opts, :limit)
    window_ms = Keyword.fetch!(opts, :window_ms)

    now = System.os_time(:millisecond)
    window = div(now, window_ms)
    bucket = {key, window}

    count = :ets.update_counter(@table, bucket, {2, 1}, {bucket, 0})

    state = %{
      limit: limit,
      remaining: max(limit - count, 0),
      reset_at: DateTime.from_unix!((window + 1) * window_ms, :millisecond)
    }

    if count > limit, do: {:error, state}, else: {:ok, state}
  end

  @doc """
  Whether `key` is currently over its limit, without counting an attempt.
  """
  @spec exceeded?(String.t(), keyword()) :: boolean()
  def exceeded?(key, opts) do
    limit = Keyword.fetch!(opts, :limit)
    window_ms = Keyword.fetch!(opts, :window_ms)
    window = div(System.os_time(:millisecond), window_ms)

    case :ets.lookup(@table, {key, window}) do
      [{_bucket, count}] -> count > limit
      [] -> false
    end
  end

  @doc """
  Forgets everything counted so far. For tests, and for an admin lifting a
  limit somebody hit by accident.
  """
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Forgets one key.
  """
  @spec reset(String.t()) :: :ok
  def reset(key) do
    :ets.match_delete(@table, {{key, :_}, :_})
    :ok
  end
end
