defmodule Mix.Tasks.Abuuba.Statuses do
  @shortdoc "Posts from elsewhere: what they cost, and pruning the old ones"

  @moduledoc """
  The posts this server has received from other servers.

      mix abuuba.statuses usage
      mix abuuba.statuses usage --days 90
      mix abuuba.statuses remove --days 90 --dry-run
      mix abuuba.statuses remove --days 90

  ## usage

  How many posts there are, how many came from elsewhere, and what the table
  costs on disk. With `--days`, also how many a prune with that cutoff would
  remove, which is the number to look at before picking one.

  ## remove

  Removes posts from other servers older than `--days` that nothing here is
  attached to. A post stays whatever its age if somebody here favourited,
  bookmarked, boosted, replied to, quoted, pinned, filtered, voted in or
  reported it, if it mentions somebody here or a notification points at it, if
  it is still in a timeline here, or if it is an ancestor of any post that
  stays.

  Posts written here are never touched. `--days` is required and has no
  default: a cutoff is a judgement about how far back this server's readers
  ever look, and it is not one to inherit from whoever wrote the task.

  Takes `--dry-run`, and the count it prints comes from the same query the
  deletion uses.

  Nothing here reclaims disk on its own. Postgres marks the rows dead and
  reuses the space for new ones, which is what an autovacuumed server wants. To
  hand it back to the filesystem after a large prune, `VACUUM FULL statuses`,
  which takes an exclusive lock and needs room for a second copy of the table.
  """

  use Mix.Task

  alias Abuuba.Ops
  alias Abuuba.Statuses.Prune

  @commands ~w(usage remove)

  @switches [days: :integer, dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    Ops.start!()

    {opts, rest, _invalid} = OptionParser.parse(args, switches: @switches)

    case rest do
      ["usage" | _rest] -> usage(opts)
      ["remove" | _rest] -> remove(opts)
      [command | _rest] -> Ops.unknown(command, @commands)
      [] -> Mix.raise("Say what to do: #{Enum.join(@commands, ", ")}")
    end
  end

  defp usage(opts) do
    # Without `--days` there is no cutoff to report against, and a default
    # would put a number next to "would be removed" that nobody asked for.
    days = Keyword.get(opts, :days)

    report =
      if is_integer(days) and days > 0, do: Prune.usage(Prune.cutoff(days)), else: Prune.usage()

    Mix.shell().info("Posts held:      #{report.total}")
    Mix.shell().info("From elsewhere:  #{report.remote}")
    Mix.shell().info("On disk:         #{report.table_size}")

    case report.removable do
      nil -> Mix.shell().info("\nPass --days to see how many a prune would remove.")
      count -> Mix.shell().info("Older than #{days} days and unattached: #{count}")
    end
  end

  defp remove(opts) do
    days = Keyword.get(opts, :days)

    unless is_integer(days) and days > 0 do
      Mix.raise("Say how far back: --days 90.")
    end

    cutoff = Prune.cutoff(days)

    if Ops.dry_run?(opts) do
      Ops.report(true, Prune.count(cutoff), "post")
    else
      {:ok, removed} = Prune.remove(cutoff)

      Ops.report(false, removed, "post")
    end
  end
end
