defmodule Mix.Tasks.Abuuba.Migrations do
  @shortdoc "Runs every migration up and back down against a scratch database"

  @moduledoc """
      mix abuuba.migrations

  Creates an empty database, applies every migration in order, rolls every one
  of them back, and drops it again. Nothing else on this machine is touched:
  the database is named after the repo's own with `_migration_check` on the
  end, and it is dropped at both ends of the run.

  ## Why this is worth a task

  A deployment applies migrations to a database that already has the previous
  ones. The test suite creates its database once and migrates it forward. So
  the two things nobody exercises are the whole chain from nothing, and the way
  back.

  The way back is the one that matters. `docs/deploy.md` tells an operator to
  reach for `Abuuba.Release.rollback/2` when a deploy goes wrong, which is
  exactly the moment to discover that a migration has no working `down`. Ecto
  will not tell you at compile time: a `change/0` it cannot reverse, or an
  `execute/1` with no second argument, fails when it is run and not before.

  Run it before a release, or after writing a migration.
  """

  use Mix.Task

  alias Ecto.Adapters.Postgres
  alias Ecto.Migrator

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    config = scratch_config()
    path = Application.app_dir(:abuuba, "priv/repo/migrations")

    Mix.shell().info("Migrating #{config[:database]} from nothing.")

    _ = Postgres.storage_down(config)
    :ok = Postgres.storage_up(config)

    {:ok, pid} = Abuuba.Repo.start_link(config)

    try do
      # Both passes load the same files, and the second load would warn about
      # redefining every module in the chain. Seventy-odd warnings is how a
      # real failure gets scrolled past.
      previous = Code.get_compiler_option(:ignore_module_conflict)
      Code.put_compiler_option(:ignore_module_conflict, true)

      {up, down} =
        try do
          up = Migrator.run(Abuuba.Repo, path, :up, all: true, log: false)
          Mix.shell().info("  #{length(up)} applied.")

          down = Migrator.run(Abuuba.Repo, path, :down, all: true, log: false)
          Mix.shell().info("  #{length(down)} rolled back.")

          {up, down}
        after
          Code.put_compiler_option(:ignore_module_conflict, previous)
        end

      report(length(up), length(down))
    after
      # Stopped before the drop and on every path, including a migration
      # raising. Postgres refuses to drop a database anything is connected to,
      # so leaving the repo running made `storage_down/1` fail quietly and the
      # task leave behind the scratch database the comment below promises it
      # will not -- which is exactly what it did until a deliberately broken
      # `down` was used to check.
      Supervisor.stop(pid)

      # Dropped whatever happened, including a migration raising: a scratch
      # database left behind is one somebody has to notice and remove by hand.
      case Postgres.storage_down(config) do
        :ok -> :ok
        other -> Mix.shell().error("Could not drop #{config[:database]}: #{inspect(other)}")
      end
    end
  end

  defp report(up, down) when up == down and up > 0 do
    Mix.shell().info("Every migration goes up and comes back down.")
  end

  defp report(up, down) do
    Mix.raise("#{up} migrations applied and #{down} rolled back; the chain is not reversible.")
  end

  # The repo's own settings, pointed at a database that exists for this run.
  # Pool settings come from the environment the task was run in and are not
  # wanted here: the sandbox pool the test environment configures cannot check
  # out a connection for a migration.
  defp scratch_config do
    :abuuba
    |> Application.get_env(Abuuba.Repo)
    |> Keyword.put(
      :database,
      "#{Application.get_env(:abuuba, Abuuba.Repo)[:database]}_migration_check"
    )
    |> Keyword.put(:pool_size, 2)
    # The repo's own query logging, which is separate from the migrator's: in
    # the development environment it prints every statement a migration runs,
    # and the point of this task is the last line.
    |> Keyword.put(:log, false)
    |> Keyword.delete(:pool)
  end
end
