defmodule Abuuba.Release do
  @moduledoc """
  The few things that have to happen outside the application, in a release.

  A release has no Mix, so `mix ecto.migrate` does not exist on a server, and
  neither does any other task an operator needs. These are the same jobs,
  callable from `bin/abuuba eval`.

  The migrations start the repository and nothing else: migrating a database
  while the web server is already serving from it is how a deploy takes the
  site down with it. The two that write through the ordinary contexts —
  `bootstrap_owner/1` and `import_mastodon/1` — start the whole application,
  because that is what those contexts need under them.
  """

  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.User
  alias Abuuba.Importer.CLI
  alias Abuuba.Roles

  @app :abuuba

  @doc """
  Brings the database up to date, creating it if this is the first boot.

  Creating it here rather than in a separate documented step, because the step
  is only ever needed once and an operator who misses it meets a connection
  error about a catalog name rather than "the database is not there yet". It is
  the same command on every deploy after that, and it does nothing.
  """
  @spec migrate() :: :ok
  def migrate do
    load()

    for repo <- repos() do
      :ok = setup_storage(repo)

      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Brings a database up to date without trying to create it.

      bin/abuuba eval 'Abuuba.Release.migrate_only()'

  For a database somebody else provisioned: a DBA-managed cluster, or one
  hardened with `REVOKE CONNECT ON DATABASE postgres FROM PUBLIC`.

  `migrate/0` asks whether the database exists, and Ecto answers that by
  connecting to the `postgres` maintenance database and looking in
  `pg_database`. Where the application's role may not connect there, that
  question cannot be asked — and a failure to ask is indistinguishable from
  "it is not there", so the code goes on to `CREATE DATABASE`, fails again, and
  reports "could not create the database" about a database that exists and is
  fully migrated. The message sends the operator to the one place the problem
  is not.

  This skips the question. If the database really is absent, the failure is a
  connection error naming it, which is the truth.
  """
  @spec migrate_only(module() | nil) :: :ok
  def migrate_only(repo \\ nil) do
    load()

    for repo <- List.wrap(repo || repos()) do
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Creates the repository's database unless it already exists.
  """
  @spec setup_storage(module()) :: :ok
  def setup_storage(repo) do
    case repo.__adapter__().storage_up(repo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> raise storage_error(reason)
    end
  end

  # Naming the maintenance database, because the most likely reason to be here
  # is that the role may not connect to it. Ecto asks whether the database
  # exists by looking in `pg_database` from `postgres`, and a failure to ask is
  # indistinguishable from an answer of no — so the next thing it tries is
  # CREATE DATABASE, and this message is about that rather than about the
  # permission. An operator reading only the first line goes looking in the
  # wrong database.
  defp storage_error(reason) do
    """
    could not create the database: #{inspect(reason)}

    If the database already exists, this is probably not about creating it.
    Ecto checks whether it exists by connecting to the maintenance database
    (`postgres`, unless :maintenance_database says otherwise), and where that
    connection is refused the check fails the same way a missing database does.

    Where the database is provisioned by somebody else, skip the check:

        bin/abuuba eval 'Abuuba.Release.migrate_only()'
    """
  end

  @doc """
  Steps the database back, one migration at a time.
  """
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load()

    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  @doc """
  Makes the first account that can open the admin area.

      bin/abuuba eval 'Abuuba.Release.bootstrap_owner(%{username: "alice", email: "alice@example.com"})'

  The one operation a fresh server genuinely needs and could not otherwise
  have. A new database has no roles, so the admin area is a door nobody can
  open, and every other way of arranging that is a mix task — which a release
  does not have.

  The account is confirmed and approved on the way in, for the same reasons
  `Abuuba.Accounts.Auth.create_by_admin/1` does it: there is nobody to send a
  confirmation link to on a server whose mail is very likely not configured
  yet, and nobody to approve the account but itself.

  The password is generated and returned. It is the only time it exists in
  readable form — the column holds a hash — so an operator who loses the line
  has to reset it rather than look it up.

  Idempotent in the part that matters: an existing role that can administer is
  reused rather than joined by a second. Two roles that both mean "can do
  everything" is the state where taking somebody's access away appears to work
  and does not.
  """
  @spec bootstrap_owner(map()) ::
          {:ok, %{account: Account.t(), user: User.t(), password: String.t()}}
          | {:error, term()}
  def bootstrap_owner(attrs) do
    start()

    password = generated_password()

    attrs = %{
      username: field(attrs, :username),
      email: field(attrs, :email),
      password: password
    }

    with {:ok, %{account: account, user: user}} <- Auth.create_by_admin(attrs),
         {:ok, role} <- Roles.administrator_role(),
         {:ok, user} <- Roles.assign(user, role) do
      {:ok, %{account: account, user: user, password: password}}
    end
  end

  @doc """
  Takes over a Mastodon instance, from a release.

      bin/abuuba eval 'Abuuba.Release.import_mastodon()'                # a dry run
      bin/abuuba eval 'Abuuba.Release.import_mastodon(execute: true)'   # do it
      bin/abuuba eval 'Abuuba.Release.import_mastodon(verify: true)'    # check it afterwards
      bin/abuuba eval 'Abuuba.Release.import_mastodon(reset: true)'     # forget them, then dry run

  `mix abuuba.import` under a different name, because a takeover is run on a
  server and a server has no Mix. Both call `Abuuba.Importer.CLI`, which starts
  the application for them — with no queues and no HTTP listener, for reasons
  that are written down there.

  A run that cannot start raises, so `bin/abuuba eval` exits non-zero and a
  script around it stops. The dry run is the default here as it is there:
  nothing is written unless `execute: true` says so.
  """
  @spec import_mastodon([CLI.option()]) :: :ok
  def import_mastodon(opts \\ []) do
    case CLI.run(opts) do
      {:ok, output} -> IO.puts(output)
      {:error, output} -> raise output
    end
  end

  # A shell hands you strings and a script hands you atoms, and an operator
  # typing this once at three in the morning should not have to know which.
  defp field(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  defp generated_password,
    do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp load do
    Application.load(@app)
  end

  # Unlike the migration functions, this one writes through the ordinary
  # contexts, so it needs the application running rather than only the repo.
  defp start do
    Application.ensure_all_started(@app)

    :ok
  end
end
