defmodule Abuuba.Importer do
  @moduledoc """
  Taking over a live Mastodon instance's database.

  ## Nothing happens until somebody has read the report

  The default is a dry run, and it is the default because the alternative is an
  admin discovering what an import does by watching it do it. The report says
  how many accounts, how many posts, how many bytes of media, and what will be
  skipped and why. A number that does not add up is what makes somebody
  distrust the whole thing, so the skips are listed rather than quietly
  subtracted.

  ## Everything is checked first, and all of it at once

  A connection that cannot be opened, a schema this code has never been
  verified against, a domain that does not match, a missing secret, a media
  root nobody can read: each is reported together rather than one per run. An
  admin should find out about all of it in one go instead of discovering the
  next problem each time they fix the last.

  ## The domain cannot change

  Every id, every URI and every signature the old server published names its
  domain. Taking over with a different `LOCAL_DOMAIN` is not a takeover: it is
  a fresh instance holding somebody else's posts, with every link on the
  network pointing at the old host. The check refuses it rather than letting
  somebody find out afterwards.

  ## Steps are checkpointed, so an interruption is not a restart

  Moving millions of rows will be interrupted. Each step records the last
  source id it wrote, and a second run continues from there. That is also why
  the steps have to be idempotent: a batch that was half written when the
  connection dropped will be seen again.

  Steps themselves arrive with their own issues. This module is the harness
  around them, and it says plainly when there are none registered rather than
  reporting a successful import that moved nothing.
  """

  alias Abuuba.Federation.URIs
  alias Abuuba.Importer.Checkpoint
  alias Abuuba.Importer.Source
  alias Abuuba.Importer.Step

  @typedoc "One thing standing in the way of an import."
  @type problem :: %{key: String.t(), detail: String.t()}

  # The schema this code has actually been read against. Anything newer may
  # have moved a column, and a column that moved is a silent mis-import: it
  # finishes, and the damage shows up months later.
  @verified_version "2026_08_03_172525"

  # The oldest schema whose shape is close enough to be read the same way.
  # Older instances have to run their own migrations first, which is a thing
  # they can do and this code cannot.
  @minimum_version "2023_01_01_000000"

  # What Mastodon needs in its environment to read its own data back. Without
  # them the rows come across and the encrypted columns in them are noise.
  @required_secrets ~w(
    SECRET_KEY_BASE
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
    ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
    VAPID_PRIVATE_KEY
    VAPID_PUBLIC_KEY
  )

  @doc "The schema version this code has been verified against."
  @spec verified_version() :: String.t()
  def verified_version, do: @verified_version

  @doc "The oldest schema version it will read."
  @spec minimum_version() :: String.t()
  def minimum_version, do: @minimum_version

  @doc "The environment variables an import needs from the old server."
  @spec required_secrets() :: [String.t()]
  def required_secrets, do: @required_secrets

  @doc """
  Every step an import runs, in order.

  Empty until the steps land. Registered rather than hardcoded so that a step
  added later cannot be forgotten by the runner.
  """
  @spec steps() :: [module()]
  def steps, do: Application.get_env(:abuuba, :import_steps, [])

  @doc """
  Reads the settings an import needs out of the environment.
  """
  @spec config(keyword()) :: keyword()
  def config(overrides \\ []) do
    defaults = [
      source_url: System.get_env("MASTODON_DATABASE_URL"),
      media_root: System.get_env("MASTODON_MEDIA_ROOT"),
      media_bucket: System.get_env("MASTODON_S3_BUCKET"),
      local_domain: System.get_env("MASTODON_LOCAL_DOMAIN") || URIs.local_domain(),
      secrets: Map.new(@required_secrets, &{&1, source_secret(&1)}),
      prefix: "",
      dry_run: true
    ]

    Keyword.merge(defaults, overrides)
  end

  # Under a `MASTODON_` name, and only that name. One of the six is
  # `SECRET_KEY_BASE`, which this server also has and cannot boot without, so a
  # release always has one set: reading the bare name as a fallback would take
  # abuuba's own key for the old server's and pass every check with it. A
  # variable nobody set has to stay unset, or the failure is silent.
  defp source_secret(name), do: System.get_env("MASTODON_" <> name) || ""

  @doc """
  Checks everything that has to be true before an import can start.

  `:ok`, or every problem at once.
  """
  @spec check(keyword()) :: :ok | {:error, [problem()]}
  def check(opts) do
    # The source check comes first and alone. Everything else reads that
    # database, so reporting five failures caused by one unreadable connection
    # would bury the answer under its own consequences.
    case check_source(opts) do
      [] -> collect(opts)
      problems -> {:error, problems}
    end
  end

  defp collect(opts) do
    problems =
      [&check_schema_version/1, &check_local_domain/1, &check_secrets/1, &check_media_root/1]
      |> Enum.flat_map(& &1.(opts))
      |> Enum.concat(step_problems(opts))

    if problems == [], do: :ok, else: {:error, problems}
  end

  # Steps get to say what would stop them before anything is written, and their
  # answers join everything else's. A precondition a step keeps to itself is
  # one an admin finds out about after `--execute`, which is after it matters.
  defp step_problems(opts), do: ask_steps(:check, 1, & &1.check(opts))

  @doc """
  What an import would do, without doing any of it.
  """
  @spec plan(keyword()) :: {:ok, map()} | {:error, [problem()]}
  def plan(opts) do
    with :ok <- check(opts) do
      {:ok,
       %{
         dry_run: Keyword.get(opts, :dry_run, true),
         source_version: schema_version(opts),
         local_domain: Keyword.get(opts, :local_domain),
         counts: counts(opts),
         skipped: skipped(),
         steps: Enum.map(steps(), &step_name/1),
         checkpoints: Checkpoint.all(),
         outcomes: %{}
       }}
    end
  end

  @doc """
  Runs an import, or reports what one would do.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) do
    with {:ok, plan} <- plan(opts) do
      if Keyword.get(opts, :dry_run, true) do
        {:ok, plan}
      else
        execute(plan, opts)
      end
    end
  end

  @doc """
  Proves an import that has already run, against the source it came from.

  Every step that can be verified is, so this grows as steps are added rather
  than staying whatever the first one happened to check.
  """
  @spec verify(keyword()) :: {:ok, [Step.verification()]} | {:error, term()}
  def verify(opts) do
    {:ok, ask_steps(:verify, 1, & &1.verify(opts))}
  end

  # `Code.ensure_loaded?/1` first, because `function_exported?/3` answers false
  # for a module that simply has not been loaded yet. Without it a step's checks
  # and verifications are silently skipped in exactly the setting they matter
  # most: a release, where nothing has loaded the module before this asks.
  defp ask_steps(function, arity, ask) do
    Enum.flat_map(steps(), fn step ->
      if Code.ensure_loaded?(step) and function_exported?(step, function, arity),
        do: ask.(step),
        else: []
    end)
  end

  @doc """
  The report, as an admin reads it.
  """
  @spec report(map()) :: String.t()
  def report(plan) do
    """
    Import plan
    ===========

    Source schema:  #{plan.source_version}
    Local domain:   #{plan.local_domain}

    Would copy
    ----------
    accounts            #{plan.counts.accounts} (#{plan.counts.local_accounts} of them local)
    users               #{plan.counts.users}
    statuses            #{plan.counts.statuses}
    media attachments   #{plan.counts.media} (#{format_bytes(plan.counts.media_bytes)})

    Would skip
    ----------
    #{skips(plan.skipped)}

    Steps
    -----
    #{steps_list(plan.steps, plan.outcomes)}

    #{closing(plan)}
    """
  end

  ## Checks

  # Reads the migrations table rather than `SELECT 1`. A connection that opens
  # onto the wrong database answers `SELECT 1` perfectly happily, and "this is
  # not a Mastodon database" is the useful thing to be told.
  defp check_source(opts) do
    case query(opts, "SELECT count(*) FROM #{table(opts, "schema_migrations")}", []) do
      {:ok, _result} ->
        []

      {:error, _reason} ->
        [
          %{
            key: "source_reachable",
            detail:
              "could not read #{table(opts, "schema_migrations")}; check the connection details and that this is a Mastodon database"
          }
        ]
    end
  end

  defp check_schema_version(opts) do
    case schema_version(opts) do
      nil ->
        [%{key: "schema_version", detail: "no schema version was found in the source database"}]

      version ->
        cond do
          version > @verified_version ->
            [
              %{
                key: "schema_version",
                detail:
                  "schema #{version} is newer than #{@verified_version}, which is the newest this code has been read against; a column that moved would be copied wrongly and silently"
              }
            ]

          version < @minimum_version ->
            [
              %{
                key: "schema_version",
                detail:
                  "schema #{version} is older than #{@minimum_version}; migrate the source instance first"
              }
            ]

          true ->
            []
        end
    end
  end

  # Read out of the source rather than taken on trust. A remote account's `uri`
  # names the server that wrote it, so the domains this instance is *not* are
  # knowable; the one it is comes from the operator, and this is where the two
  # are compared. An admin who mistypes the variable would otherwise pass a
  # check that exists to catch exactly that.
  defp check_local_domain(opts) do
    declared = to_string(Keyword.get(opts, :local_domain))
    found = source_domain(opts)

    cond do
      declared != URIs.local_domain() ->
        [
          %{
            key: "local_domain",
            detail:
              "the source is #{declared} and this server is #{URIs.local_domain()}; every id and signature ever published carries the domain, so a takeover has to keep it"
          }
        ]

      is_binary(found) and found != URIs.local_domain() ->
        [
          %{
            key: "local_domain",
            detail:
              "the source database's own posts name #{found}, not #{URIs.local_domain()}; check MASTODON_LOCAL_DOMAIN and this server's domain"
          }
        ]

      true ->
        []
    end
  end

  # From a local post's own URI, which is the one place the source records the
  # domain it was writing under. Null where the instance has never posted,
  # which is a state worth allowing rather than refusing.
  defp source_domain(opts) do
    sql = """
    SELECT uri FROM #{table(opts, "statuses")}
    WHERE uri IS NOT NULL AND local = true
    LIMIT 1
    """

    case query(opts, sql, []) do
      {:ok, %{rows: [[uri]]}} when is_binary(uri) -> authority(uri)
      _ -> nil
    end
  end

  # Host and port, because a development instance is `localhost:4000` and
  # comparing only the host would call that a match for every server on the
  # machine. The port is dropped where it is the scheme's default, which is
  # how the domain is written everywhere else.
  defp authority(uri) do
    case URI.parse(uri) do
      %URI{host: host, port: port, scheme: scheme} when is_binary(host) ->
        if port in [nil, default_port(scheme)], do: host, else: "#{host}:#{port}"

      _ ->
        nil
    end
  end

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_scheme), do: nil

  defp check_secrets(opts) do
    secrets = Keyword.get(opts, :secrets, %{})

    missing = Enum.filter(@required_secrets, &(Map.get(secrets, &1, "") in [nil, ""]))

    if missing == [] do
      []
    else
      [
        %{
          key: "secrets",
          # Named the way an admin sets them, which is with the prefix. An
          # error that names `SECRET_KEY_BASE` sends somebody to the variable
          # this server needs for itself.
          detail:
            "missing from the environment: #{Enum.map_join(missing, ", ", &("MASTODON_" <> &1))}"
        }
      ]
    end
  end

  # Only where one was named. A server whose media lives in a bucket has no
  # local root, and demanding one would refuse a perfectly ordinary setup.
  defp check_media_root(opts) do
    case Keyword.get(opts, :media_root) do
      root when is_binary(root) and root != "" ->
        if File.dir?(root),
          do: [],
          else: [%{key: "media_root", detail: "#{root} is not a directory this server can read"}]

      _ ->
        []
    end
  end

  ## The plan

  defp counts(opts) do
    %{
      accounts: count(opts, "accounts"),
      local_accounts: count(opts, "accounts", "domain IS NULL"),
      users: count(opts, "users"),
      statuses: count(opts, "statuses", "deleted_at IS NULL"),
      media: count(opts, "media_attachments"),
      media_bytes: media_bytes(opts)
    }
  end

  defp count(opts, table, where \\ nil) do
    clause = if where, do: " WHERE " <> where, else: ""

    case query(opts, "SELECT count(*) FROM #{table(opts, table)}#{clause}", []) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  # Only what this server would hold. Remote media is a cache that can be
  # fetched again, and counting it would tell an admin to buy disk for files
  # nothing is going to copy.
  defp media_bytes(opts) do
    sql = """
    SELECT coalesce(sum(coalesce(file_file_size, 0) + coalesce(thumbnail_file_size, 0)), 0)
    FROM #{table(opts, "media_attachments")}
    WHERE remote_url IS NULL OR remote_url = ''
    """

    case query(opts, sql, []) do
      {:ok, %{rows: [[bytes]]}} -> trunc(bytes)
      _ -> 0
    end
  end

  defp skipped do
    [
      %{
        what: "statuses",
        reason: "rows already deleted on the source are not copied"
      },
      %{
        what: "media_attachments",
        reason:
          "files from other servers are a cache and are re-fetched rather than copied; only local bytes are counted"
      },
      %{
        what: "sessions",
        reason: "everybody signs in again after a takeover; a copied session is a copied cookie"
      }
    ]
  end

  ## Running

  # The plan, with what each step did added to it. A run that answered with
  # something else took the report down with it, at the end of an import that
  # had already written everything.
  defp execute(plan, opts) do
    case steps() do
      [] ->
        {:error, :no_steps}

      steps ->
        with {:ok, outcomes} <- run_steps(steps, opts) do
          {:ok, Map.put(plan, :outcomes, outcomes)}
        end
    end
  end

  defp run_steps(steps, opts) do
    Enum.reduce_while(steps, {:ok, %{}}, fn step, {:ok, acc} ->
      name = step_name(step)

      case run_step(step, name, opts) do
        {:ok, outcome} -> {:cont, {:ok, Map.put(acc, name, outcome)}}
        {:error, reason} -> {:halt, {:error, {name, reason}}}
      end
    end)
  end

  # A step that already finished is skipped rather than run again. That is what
  # makes a second attempt a continuation instead of a second import.
  defp run_step(step, name, opts) do
    if Checkpoint.finished?(name) do
      {:ok, :already_done}
    else
      case step.run(opts) do
        :ok ->
          Checkpoint.finish(name)

          {:ok, :done}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp step_name(step) do
    step |> Module.split() |> List.last() |> Macro.underscore()
  end

  ## Plumbing

  # Through the caller's repo, which against a real instance is a connection to
  # the source database and in a test is this one with a table prefix. Every
  # query is then the query it would really run.
  defp query(opts, sql, params), do: Source.query(opts, sql, params)

  defp table(opts, name), do: Source.table(opts, name)

  defp schema_version(opts) do
    sql = "SELECT max(version) FROM #{table(opts, "schema_migrations")}"

    case query(opts, sql, []) do
      {:ok, %{rows: [[version]]}} when is_binary(version) -> version
      _ -> nil
    end
  end

  defp skips(skipped) do
    Enum.map_join(skipped, "\n", fn %{what: what, reason: reason} ->
      "#{String.pad_trailing(what, 20)}#{reason}"
    end)
  end

  defp steps_list([], _outcomes), do: "none registered yet; nothing would be written"

  defp steps_list(steps, outcomes) do
    Enum.map_join(steps, "\n", fn step ->
      case Map.get(outcomes, step) do
        nil -> "  " <> step
        outcome -> "  #{String.pad_trailing(step, 20)}#{outcome}"
      end
    end)
  end

  defp closing(%{dry_run: true}),
    do: "This was a dry run: nothing has been written. Add --execute to run it."

  defp closing(_plan), do: "Ready to run."

  defp format_bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} kB"
  defp format_bytes(bytes), do: "#{bytes} bytes"
end
