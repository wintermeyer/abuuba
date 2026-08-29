defmodule Abuuba.Federation.HTTP.CircuitBreakerTest do
  @moduledoc """
  The breaker has to close again on a host that is still down.

  Opening was the part that worked. What did not was re-arming: the timestamp
  was written only on the failure that crossed the threshold exactly, so the
  probe let through after the cooldown could fail and leave the old, expired
  timestamp standing. From then on every check read "expired" and every
  delivery to a dead host went out to wait the full timeout -- the breaker
  quietly stopped existing after sixty seconds, which is exactly when a host
  that is really gone starts to matter.

  Both sides of the gate are asserted here, and the cooldown is configurable so
  that asking about them costs milliseconds rather than a minute.
  """
  use Abuuba.DataCase, async: false

  alias Abuuba.Federation.HTTP.CircuitBreaker

  @host "still-down.example"

  defp cooldown_ms, do: Application.get_env(:abuuba, :federation_circuit_cooldown_ms, 60_000)

  defp knock_out(host) do
    for _ <- 1..CircuitBreaker.failure_threshold(), do: CircuitBreaker.failed(host)
  end

  test "a host nobody has complained about is asked" do
    # The positive control. Without it every assertion below would pass on a
    # breaker that refused everything.
    assert CircuitBreaker.check(@host) == :ok
  end

  test "enough failures in a row close it off" do
    knock_out(@host)

    assert CircuitBreaker.check(@host) == {:error, :circuit_open}
  end

  test "the cooldown lets a request through again" do
    knock_out(@host)
    Process.sleep(cooldown_ms() * 3)

    assert CircuitBreaker.check(@host) == :ok,
           "the cooldown never expired, so a host that came back stays shut out"
  end

  test "and a host that is still down closes again" do
    knock_out(@host)
    Process.sleep(cooldown_ms() * 3)

    # The probe the cooldown allowed, and it fails: the host is still gone.
    CircuitBreaker.failed(@host)

    assert CircuitBreaker.check(@host) == {:error, :circuit_open},
           "the breaker did not re-arm, so every later delivery waits the full timeout"
  end

  test "a host that answers is forgiven everything" do
    knock_out(@host)
    CircuitBreaker.succeeded(@host)

    assert CircuitBreaker.check(@host) == :ok
  end
end
