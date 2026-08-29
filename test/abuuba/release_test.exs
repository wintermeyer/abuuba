defmodule Abuuba.ReleaseTest do
  # Not async: it creates and drops a database of its own.
  use ExUnit.Case, async: false

  alias Abuuba.Release
  alias Ecto.Adapters.Postgres

  describe "setup" do
    test "creates the database when it is not there yet" do
      # The first boot of a new instance. An operator following the deploy
      # docs has a Postgres and a role and nothing else, and a `migrate` that
      # assumes the database already exists fails on the one run where the
      # failure is least understandable.
      repo = scratch_repo("abuuba_release_absent_test")

      on_exit(fn -> Postgres.storage_down(repo.config()) end)

      assert :ok = Release.setup_storage(repo)
      assert :up = Postgres.storage_status(repo.config())
    end

    test "and says so without failing when it is already there" do
      # The second boot, and every deploy after it. This is the common case,
      # so it has to be quiet rather than an error the operator learns to
      # ignore.
      repo = scratch_repo("abuuba_release_present_test")
      Postgres.storage_up(repo.config())

      on_exit(fn -> Postgres.storage_down(repo.config()) end)

      assert :ok = Release.setup_storage(repo)
      assert :up = Postgres.storage_status(repo.config())
    end
  end

  describe "migrating a database somebody else provisioned" do
    test "migrate_only/1 brings it up to date without touching anything else" do
      repo = scratch_repo("abuuba_release_migrate_only_test")
      Postgres.storage_up(repo.config())

      on_exit(fn -> Postgres.storage_down(repo.config()) end)

      assert :ok = Release.migrate_only(repo)
      assert [_ | _] = migrated_versions(repo)
    end

    test "and running it a second time is quiet" do
      repo = scratch_repo("abuuba_release_migrate_only_again_test")
      Postgres.storage_up(repo.config())

      on_exit(fn -> Postgres.storage_down(repo.config()) end)

      assert :ok = Release.migrate_only(repo)
      before = migrated_versions(repo)

      assert :ok = Release.migrate_only(repo)
      assert migrated_versions(repo) == before
    end

    test "it says the database is missing rather than trying to create one" do
      # The whole point of the split. `migrate/0` would create it here; this
      # one is for an operator who knows the database is provisioned and wants
      # a failure that names the real problem.
      repo = scratch_repo("abuuba_release_migrate_only_absent_test")
      Postgres.storage_down(repo.config())

      assert_raise DBConnection.ConnectionError, fn -> Release.migrate_only(repo) end
    end
  end

  describe "a cluster where the maintenance database cannot be reached" do
    # `REVOKE CONNECT ON DATABASE postgres FROM PUBLIC` is the real-world
    # version. Pointing the check at a database that does not exist fails in
    # exactly the same place and needs no permissions changed on the cluster
    # running these tests.
    setup do
      # Made with a working maintenance database, because creating it needs one
      # too. Only then is the check pointed somewhere unreachable, which is the
      # state the operator is in: the database is there, and the question about
      # it cannot be asked.
      repo = scratch_repo("abuuba_release_hardened_test")
      reachable = repo.config()
      Postgres.storage_up(reachable)

      on_exit(fn -> Postgres.storage_down(reachable) end)

      %{
        repo:
          scratch_repo("abuuba_release_hardened_test", maintenance_database: "no_such_db_here")
      }
    end

    test "setup_storage says so, and says what to do about it", %{repo: repo} do
      # The failure the operator actually meets: a database that is present and
      # migrated, reported as one that could not be created.
      error = assert_raise RuntimeError, fn -> Release.setup_storage(repo) end

      assert error.message =~ "maintenance"
      assert error.message =~ "migrate_only"
    end

    test "and migrate_only/1 migrates it anyway", %{repo: repo} do
      assert :ok = Release.migrate_only(repo)
      assert [_ | _] = migrated_versions(repo)
    end
  end

  # Read straight from the table the migrator keeps, so a migration that ran is
  # a row rather than the absence of an exception.
  defp migrated_versions(repo) do
    {:ok, versions, _apps} =
      Ecto.Migrator.with_repo(repo, fn r ->
        Ecto.Migrator.migrated_versions(r)
      end)

    versions
  end

  # A repo module pointed at a database name nothing else uses, configured from
  # the test repo so it reaches the same Postgres with the same credentials.
  defp scratch_repo(database, extra \\ []) do
    config =
      Abuuba.Repo.config()
      |> Keyword.put(:database, database)
      |> Keyword.merge(extra)
      # A repo's migrations are found under its own name by default, and this
      # one has no directory. Without this the migrator finds nothing and
      # reports success for having run none of them.
      |> Keyword.put(:priv, "priv/repo")
      |> Keyword.drop([:pool, :ownership_timeout])

    Application.put_env(:abuuba, Abuuba.ReleaseTest.ScratchRepo, config)

    Abuuba.ReleaseTest.ScratchRepo
  end
end

defmodule Abuuba.ReleaseTest.ScratchRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :abuuba, adapter: Ecto.Adapters.Postgres
end
