defmodule Abuuba.SharedTableIsolationTest do
  @moduledoc """
  What one test leaves behind for the next one.

  The database sandbox rolls back rows and cannot touch ETS, so a named table
  that outlives a test is shared by the whole run. Two of them are: the rate
  limit buckets and the delivery circuit breaker, both keyed by host or
  address, and every federation test in the suite talks to `remote.example`.

  The breaker is the one that hurt. Five failed deliveries anywhere in the run
  opened it, and every later test that expected a fetch to succeed was handed
  `{:error, :circuit_open}` instead. Which tests those were depended on the
  seed, so it surfaced as two or three failures wandering between files
  between runs, each of them passing when its file was run alone.

  These two tests are deliberately in this order, and the second is the one
  that matters: it fails if the setup ever stops clearing what the first left.
  """
  use Abuuba.DataCase, async: false

  alias Abuuba.Federation.HTTP.CircuitBreaker
  alias Abuuba.RateLimit

  @host "remote.example"

  test "one test can knock a peer out" do
    for _ <- 1..5, do: CircuitBreaker.failed(@host)

    assert CircuitBreaker.check(@host) == {:error, :circuit_open}
  end

  test "and the next one finds it standing" do
    assert CircuitBreaker.check(@host) == :ok,
           "the breaker carried a previous test's failures into this one"
  end

  test "the same for a bucket somebody emptied" do
    assert {:ok, _remaining} = RateLimit.hit("shared-table-test", limit: 1, window_ms: 60_000)

    assert {:error, :rate_limited} =
             RateLimit.hit("shared-table-test", limit: 1, window_ms: 60_000)
  end

  test "and the next one has its own" do
    assert {:ok, _remaining} = RateLimit.hit("shared-table-test", limit: 1, window_ms: 60_000),
           "a bucket a previous test emptied was still empty here"
  end
end
