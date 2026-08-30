defmodule Mix.Tasks.Abuuba.Import do
  @shortdoc "Reports on, and runs, a takeover of a Mastodon database"

  @moduledoc """
  Moves a live Mastodon instance into abuuba.

      $ mix abuuba.import                 # a dry run: says what would happen
      $ mix abuuba.import --execute       # actually does it
      $ mix abuuba.import --reset         # forgets the checkpoints and starts over
      $ mix abuuba.import --verify        # checks an import that has already run

  ## Not on a server

  This needs a checkout. A server runs a release, a release has no Mix, and the
  same command there is `Abuuba.Release.import_mastodon/1`:

      $ bin/abuuba eval 'Abuuba.Release.import_mastodon(execute: true)'

  Both are front ends for `Abuuba.Importer.CLI`, so neither can grow a flag the
  other does not have.

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

      MASTODON_SECRET_KEY_BASE
      MASTODON_ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
      MASTODON_ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
      MASTODON_ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
      MASTODON_VAPID_PRIVATE_KEY
      MASTODON_VAPID_PUBLIC_KEY

  The prefix is required, with no fallback to the bare name: `SECRET_KEY_BASE`
  is also this server's, and reading that one instead would pass every check
  with the wrong key.

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

  alias Abuuba.Importer.CLI

  # `app.config` rather than `app.start`: the command starts the application
  # itself, in the shape an import wants it rather than the shape a server
  # does, and it cannot do that once something else has started it.
  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: CLI.switches())

    case CLI.run(opts) do
      {:ok, output} -> Mix.shell().info(output)
      {:error, output} -> Mix.raise(output)
    end
  end
end
