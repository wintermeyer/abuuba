defmodule Abuuba.Federation.HTTP.CircuitBreaker do
  @moduledoc """
  Stops asking a host that has stopped answering.

  A server that has gone down does not fail fast; it fails slowly, by taking
  the full timeout on every request. With thousands of deliveries queued for a
  popular instance, that turns one dead host into a lot of workers doing
  nothing but waiting. So after enough consecutive failures the host is refused
  immediately, and after a cooling-off period requests are tried again to find
  out whether it came back. One that fails shuts the host for another
  cooling-off period; one that succeeds clears the record entirely.

  Not a strict single-probe half-open state, deliberately: refusing costs
  nothing, so a minute's worth of workers finding out together that a host is
  still down is a bounded waste, and holding exactly one of them back is
  co-ordination this does not otherwise need.

  Counted in this node's memory, like the rate limiter, and for the same
  reason: a shared store would be a second thing to run. Each node forming its
  own opinion of a host is fine here, because the opinion is only ever "stop
  wasting time on this one for a minute".
  """

  use GenServer

  @table __MODULE__

  @failure_threshold 5
  @cooldown_ms 60_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

    {:ok, %{}}
  end

  @doc """
  Whether a request to this host should even be attempted.
  """
  @spec check(String.t()) :: :ok | {:error, :circuit_open}
  def check(host) do
    case :ets.lookup(@table, host) do
      [{^host, failures, opened_at}] when failures >= @failure_threshold ->
        if expired?(opened_at), do: :ok, else: {:error, :circuit_open}

      _ ->
        :ok
    end
  end

  @doc """
  Records that a host answered. Clears whatever it owed.
  """
  @spec succeeded(String.t()) :: :ok
  def succeeded(host) do
    :ets.delete(@table, host)
    :ok
  end

  @doc """
  Records that a host did not answer.
  """
  @spec failed(String.t()) :: :ok
  def failed(host) do
    failures = :ets.update_counter(@table, host, {2, 1}, {host, 0, nil})

    # At the threshold and every failure past it, not only the one that crossed
    # it. Stamping just the fifth left the probe that the cooldown allowed
    # writing no timestamp when it failed, so the old one stood, stayed
    # expired, and the breaker let everything through from then on -- it
    # stopped existing after sixty seconds, on exactly the hosts it is for.
    if failures >= @failure_threshold do
      :ets.insert(@table, {host, failures, System.monotonic_time(:millisecond)})
    end

    :ok
  end

  @doc """
  Forgets everything. For tests, and for an admin who has just fixed a peer.
  """
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  How many consecutive failures close a host off.
  """
  def failure_threshold, do: @failure_threshold

  # After the cooldown, requests are tried again. One that fails shuts the host
  # for another cooldown, because every failure at or past the threshold stamps
  # the time afresh; one that succeeds deletes the entry.
  defp expired?(nil), do: true

  defp expired?(opened_at) do
    System.monotonic_time(:millisecond) - opened_at > cooldown_ms()
  end

  # Configurable so that a test can ask what happens on either side of the gate
  # without waiting out a minute of real time.
  defp cooldown_ms,
    do: Application.get_env(:abuuba, :federation_circuit_cooldown_ms, @cooldown_ms)
end
