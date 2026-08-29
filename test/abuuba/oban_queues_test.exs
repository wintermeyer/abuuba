defmodule Abuuba.ObanQueuesTest do
  @moduledoc """
  Every worker's queue is one Oban actually runs.

  A worker whose queue is not in the config enqueues jobs that sit in
  `available` forever: nothing errors, nothing retries, nothing logs. That is
  how poll expiry and the remote-status vacuum were dead in production while
  every test passed -- the test mode executes jobs inline whatever their
  queue, so only the running system ever notices, and it notices by silently
  not doing the work. The bench caught it: its drain-wait watched the cron
  insert one `PollExpiryWorker` job per minute that no queue would ever take.

  Enumerated rather than listed, so a new worker with a typoed queue fails
  here on the day it is written.
  """
  use ExUnit.Case, async: true

  test "every Oban worker enqueues into a configured queue" do
    configured = Application.get_env(:abuuba, Oban)[:queues] |> Keyword.keys()

    {:ok, modules} = :application.get_key(:abuuba, :modules)

    workers =
      for mod <- modules,
          Code.ensure_loaded?(mod),
          mod.module_info(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()
          |> Enum.member?(Oban.Worker),
          do: mod

    assert workers != [], "found no Oban workers -- the enumeration is broken"

    for mod <- workers do
      queue = Keyword.get(mod.__opts__(), :queue, :default)

      assert queue in configured,
             "#{inspect(mod)} enqueues into #{inspect(queue)}, which no queue runs -- " <>
               "its jobs would sit in `available` forever (configured: #{inspect(configured)})"
    end
  end

  test "every cron entry names a worker" do
    # The other half: a crontab pointing at a module that is not a worker (or
    # was renamed) would raise only inside Oban's plugin, at runtime.
    # `Oban.Cron`, not `Oban.Plugins.Cron`: the latter is a deprecated shim in
    # Oban 2.24 that delegates here, and matching on it would keep passing
    # while the config quietly ran on a deprecation.
    {Oban.Cron, opts} =
      Application.get_env(:abuuba, Oban)[:plugins]
      |> Enum.find(&match?({Oban.Cron, _opts}, &1))

    crontab = Keyword.fetch!(opts, :crontab)

    for {_schedule, mod} <- crontab do
      assert Code.ensure_loaded?(mod) and function_exported?(mod, :perform, 1),
             "the crontab names #{inspect(mod)}, which is not an Oban worker"
    end
  end
end
