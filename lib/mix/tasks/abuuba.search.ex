defmodule Mix.Tasks.Abuuba.Search do
  @shortdoc "Search indexes: what they cost, and rebuilding them"

  @moduledoc """
  The indexes search runs on.

      mix abuuba.search usage
      mix abuuba.search reindex

  ## There is nothing to re-extract

  Worth saying plainly, because this is the command an admin arrives at from a
  Mastodon habit where reindexing means feeding every post to Elasticsearch
  again. Here the searchable text is a generated column: Postgres computes it
  from the row as the row is written, so it is never out of date and there is
  no state that can drift.

  ## usage

  How much disk each search index is holding, largest first.

  ## reindex

  Rebuilds them. There are two reasons to, and neither is "search is missing
  something": an index corrupted by hardware or a crash, and a major Postgres
  upgrade or a collation change, after which text indexes have to be rebuilt to
  be trusted.

  Runs `REINDEX INDEX CONCURRENTLY` — the writes keep working while it does,
  which on a table the size of `statuses` is the difference between a rebuild
  and an outage. A concurrent rebuild that fails leaves an invalid index
  behind; this reports which, so it can be dropped rather than quietly
  answering nothing.
  """

  use Mix.Task

  alias Abuuba.Ops
  alias Abuuba.Repo

  @commands ~w(usage reindex)

  # The indexes search actually uses. Named rather than discovered, so this
  # cannot start rebuilding a primary key somebody added later.
  @indexes ~w(
    accounts_searchable_index
    accounts_username_trgm_index
    accounts_display_name_trgm_index
    statuses_searchable_index
  )

  @impl Mix.Task
  def run(args) do
    Ops.start!()

    {_opts, rest, _invalid} = OptionParser.parse(args, switches: [])

    case rest do
      ["usage" | _rest] -> usage()
      ["reindex" | _rest] -> reindex()
      [command | _rest] -> Ops.unknown(command, @commands)
      [] -> Mix.raise("Say what to do: #{Enum.join(@commands, ", ")}")
    end
  end

  defp usage do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)), idx_scan
        FROM pg_stat_user_indexes
        WHERE indexrelname = ANY($1)
        ORDER BY pg_relation_size(indexrelid) DESC
        """,
        [@indexes]
      )

    Mix.shell().info("Index\t\t\t\t\tSize\tScans")

    Enum.each(rows, fn [name, size, scans] ->
      Mix.shell().info("#{String.pad_trailing(name, 40)}#{size}\t#{scans}")
    end)

    invalid()
  end

  defp reindex do
    Enum.each(@indexes, fn index ->
      Mix.shell().info("Rebuilding #{index} ...")

      # Outside a transaction, which is what CONCURRENTLY requires. The Ecto
      # sandbox is not in play here: this task runs against a real database.
      Repo.query!("REINDEX INDEX CONCURRENTLY #{index}", [], timeout: :infinity)
    end)

    Mix.shell().info("Done.")

    invalid()
  end

  # Said after either command. An invalid index is not an error Postgres
  # reports on the next query — it is simply not used, so search quietly gets
  # slower and nobody knows why.
  defp invalid do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.relname
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        WHERE NOT i.indisvalid AND c.relname = ANY($1)
        """,
        [@indexes]
      )

    case rows do
      [] ->
        :ok

      rows ->
        names = Enum.map_join(rows, ", ", fn [name] -> name end)

        Mix.shell().error("""
        These are invalid and are not being used: #{names}
        A concurrent rebuild that failed leaves one behind. Drop it and run this again.
        """)
    end
  end
end
