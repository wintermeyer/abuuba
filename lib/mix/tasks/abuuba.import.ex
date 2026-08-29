defmodule Mix.Tasks.Abuuba.Import do
  @shortdoc "Reports on, and runs, a takeover of a Mastodon database"

  @moduledoc """
  Moves a live Mastodon instance into abuuba.

      $ mix abuuba.import                 # a dry run: says what would happen
      $ mix abuuba.import --execute       # actually does it
      $ mix abuuba.import --reset         # forgets the checkpoints and starts over
      $ mix abuuba.import --verify        # checks an import that has already run

  ## The dry run is the default on purpose

  The alternative is an admin discovering what an import does by watching it do
  it, on a database somebody's server depends on. A dry run reads, counts and
  reports, and writes nothing at all.

  ## What it needs

      MASTODON_DATABASE_URL   the source database
      MASTODON_MEDIA_ROOT     where its files are, if they are on disk
      MASTODON_S3_BUCKET      or the bucket they are in

  plus the secrets the old server used, because rows come across with encrypted
  columns in them and without the keys those columns are noise:

      SECRET_KEY_BASE
      ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
      ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
      ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
      VAPID_PRIVATE_KEY
      VAPID_PUBLIC_KEY

  ## The domain has to stay the same

  Every id, every URI and every signature the old server ever published names
  its domain. A takeover onto a different `LOCAL_DOMAIN` is not a takeover: it
  is a fresh instance holding somebody else's posts, with every link on the
  network still pointing at the old host. The check refuses it.

  ## Verifying afterwards

  `--verify` needs the source database to still be there, because it compares
  against it: it signs a request with each imported key and checks the
  signature against the public half the old server published, and it compares
  the actor URL and webfinger name this server would publish with the ones that
  one did. Both are things that either match or the fediverse stops talking to
  this server, and finding out in the maintenance window beats finding out from
  the first delivery that bounces.

  ## It can be run again

  Each step records how far it got. An import interrupted by a timeout, a
  closed laptop or one bad row is continued rather than restarted; `--reset`
  is there for the case where somebody means to start over.
  """

  use Mix.Task

  alias Abuuba.Importer
  alias Abuuba.Importer.Checkpoint
  alias Abuuba.Importer.SourceRepo

  @requirements ["app.start"]

  @switches [execute: :boolean, reset: :boolean, verify: :boolean, media_root: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    if opts[:reset], do: reset()

    config = Importer.config(dry_run: !opts[:execute])

    config =
      if opts[:media_root], do: Keyword.put(config, :media_root, opts[:media_root]), else: config

    config = Keyword.put(config, :repo, source_repo(config))

    if opts[:verify], do: verify(config), else: take_over(config)
  end

  defp take_over(config) do
    case Importer.run(config) do
      {:ok, plan} -> report(plan)
      {:error, :no_steps} -> Mix.raise(no_steps())
      {:error, problems} when is_list(problems) -> Mix.raise(problems_message(problems))
      {:error, {step, reason}} -> Mix.raise("step #{step} stopped: #{inspect(reason)}")
    end
  end

  defp reset do
    Checkpoint.reset()

    Mix.shell().info("Checkpoints cleared; the next run starts from the beginning.")
  end

  # A second connection, opened for this task alone. Not an application repo:
  # the source database is somebody else's and is only ever read, and a repo in
  # the supervision tree would try to connect on every boot.
  defp source_repo(config) do
    case config[:source_url] do
      url when is_binary(url) and url != "" ->
        {:ok, _pid} = SourceRepo.connect(url)

        SourceRepo

      _ ->
        Mix.raise("""
        MASTODON_DATABASE_URL is not set.

        It is the connection string for the instance being taken over, and
        everything this task does starts by reading it.
        """)
    end
  end

  defp report(plan) do
    Mix.shell().info(Importer.report(plan))
  end

  defp verify(config) do
    {:ok, verifications} = Importer.verify(config)

    Mix.shell().info(verification(verifications))

    if Enum.any?(verifications, &(&1.failures != [])) do
      Mix.raise("The import does not check out. Nothing above is a warning.")
    end
  end

  # Whatever the steps reported, in one shape, so that a step added later shows
  # up here without this task being edited.
  defp verification([]) do
    """
    Verification
    ============

    No step has anything it can verify.
    """
  end

  defp verification(verifications) do
    """
    Verification
    ============

    #{Enum.map_join(verifications, "\n\n", &one_verification/1)}
    """
  end

  defp one_verification(%{name: name, checked: checked, failures: failures}) do
    """
    #{name}: #{checked} checked, #{length(failures)} that do not match
    #{failures(failures)}
    """
  end

  defp failures([]), do: "  all good"

  defp failures(rows), do: Enum.map_join(rows, "\n", &("  " <> inspect(&1)))

  defp problems_message(problems) do
    """
    The import cannot start yet:

    #{Enum.map_join(problems, "\n", fn problem -> "  * #{problem.key}: #{problem.detail}" end)}

    Nothing has been written.
    """
  end

  defp no_steps do
    """
    No import steps are registered, so an --execute run would move nothing.

    They are configuration: see `:import_steps` in config/config.exs. An empty
    list is a misconfiguration rather than a quiet no-op, so this says so
    instead of reporting a successful import of nothing.
    """
  end
end
