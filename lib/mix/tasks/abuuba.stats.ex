defmodule Mix.Tasks.Abuuba.Stats do
  @shortdoc "Counter caches: what has drifted, and putting it right"

  @moduledoc """
      mix abuuba.stats drift
      mix abuuba.stats recount
      mix abuuba.stats recount --dry-run

  ## drift

  How many counter rows disagree with the rows they cache, without writing
  anything. `Abuuba.Stats` says the counters are a cache and the rows in
  `favourites`, `follows` and `statuses` are the truth; this is how you find
  out whether the two still agree.

  Nothing to report is the normal answer. Counters are maintained by single
  statements Postgres evaluates, so they do not drift on their own; they drift
  when something died between writing a row and counting it, or when a restore
  brought one table back further than another.

  ## recount

  Recomputes them from those rows and says how many had to change. Two
  statements rather than a walk, so a server with a million accounts is not a
  million queries.

  `--dry-run` reports what `drift` reports and writes nothing, so
  `recount --dry-run` and `drift` are the same question asked two ways.

  ## What it does not touch

  `last_status_at`. An imported post moves the counters and deliberately does
  not move that, because an archive is old news and stamping it would put a
  decade-old post forward as the latest thing somebody said. Recomputing it
  would undo that on every server that has run an import.
  """

  use Mix.Task

  alias Abuuba.Ops
  alias Abuuba.Stats

  @commands ~w(drift recount)

  @switches [dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    Ops.start!()

    {opts, rest, _invalid} = OptionParser.parse(args, switches: @switches)

    case rest do
      ["drift" | _rest] -> report(Stats.drift(), true)
      ["recount" | _rest] -> recount(opts)
      [command | _rest] -> Ops.unknown(command, @commands)
      [] -> Mix.raise("Say what to do: #{Enum.join(@commands, ", ")}")
    end
  end

  defp recount(opts) do
    if Ops.dry_run?(opts) do
      report(Stats.drift(), true)
    else
      report(Stats.recount(), false)
    end
  end

  defp report(%{accounts: accounts, statuses: statuses}, dry_run?) do
    Ops.report(dry_run?, accounts, "account counter")
    Ops.report(dry_run?, statuses, "status counter")
  end
end
