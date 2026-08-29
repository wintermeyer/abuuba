defmodule Abuuba.Importer.Batch do
  @moduledoc """
  Copying a source table, one page at a time, with a mark saying how far it got.

  Every part of every step is the same shape: read rows by ascending id, turn
  each one into a row for here, write them, record the highest id seen. That is
  the whole of what makes an import resumable, and it lives here rather than in
  whichever step needed it first so that the next one inherits it instead of
  writing it again slightly differently.

  Three decisions are made once, here:

    * **How big a page is.** Small enough that an interruption costs little,
      large enough that the round trip is not the cost.

    * **What idempotent means.** A page and the mark that says it was written
      go in together, in one transaction, so an import killed between the two
      cannot resume from before rows it already wrote. That is what makes a
      part safe even where the target has no natural key to conflict on —
      moderation notes and audit log entries have only a serial id, and
      `on_conflict: :nothing` has nothing to fire on for them.

      The conflict clause is still there, for the case where somebody clears
      the checkpoints and runs it again over rows that are already here.

    * **What a checkpoint is called.** `step/part`, built here, so that
      `--reset` and the report see one convention rather than whatever each
      step chose to spell it.
  """

  alias Abuuba.Importer.Checkpoint
  alias Abuuba.Importer.Source
  alias Abuuba.Repo

  @batch 500

  @typedoc """
  Turns one page of source rows into rows for here.

  Given the page as maps keyed by column name, returns `{:ok, rows}` or an
  error that stops the import. A builder rather than a per-row function because
  some parts need the whole page to answer a question: which key an account
  signs with cannot be decided one row at a time.
  """
  @type builder :: ([map()] -> {:ok, [map()]} | {:error, term()})

  @doc """
  Copies a source query into a table here, page by page.

  `mapper` sees one source row and returns one row to write, `nil` to skip it,
  or `{:error, reason}` to stop the import. The SQL is wrapped, so it must not
  carry its own `ORDER BY` or `LIMIT` and must select an `id`.

  Skipping is a row the source has and this side has no place for — a setting
  nothing here reads, a record of something abuuba does not do. Dropping it in
  the mapper keeps the decision next to the mapping it belongs to.
  """
  @spec copy(keyword(), String.t(), module(), String.t(), (map() -> map() | {:error, term()})) ::
          :ok | {:error, term()}
  def copy(opts, step, schema, sql, mapper) do
    page(opts, step, schema, sql, fn rows -> rows |> Enum.map(mapper) |> first_error() end)
  end

  @doc """
  The same, for a part that has to see the whole page at once.
  """
  @spec page(keyword(), String.t(), module(), String.t(), builder()) :: :ok | {:error, term()}
  def page(opts, step, schema, sql, builder) do
    paged = """
    SELECT * FROM (#{sql}) AS source
    WHERE source.id > $1
    ORDER BY source.id ASC
    LIMIT #{@batch}
    """

    do_page(opts, step, schema, paged, builder, Checkpoint.last_id(step) || 0)
  end

  @doc """
  Runs a step's parts in order, stopping at the first that fails.

  Every step is a list of named parts and every one of them is copied the same
  way, so the loop is here rather than four times over. The name comes back in
  the error so that a failure says which part stopped rather than only that the
  step did.
  """
  @spec run_parts(keyword(), [{atom(), (keyword(), atom() -> :ok | {:error, term()})}]) ::
          :ok | {:error, {atom(), term()}}
  def run_parts(opts, parts) do
    Enum.reduce_while(parts, :ok, fn {name, copier}, :ok ->
      case copier.(opts, name) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {name, reason}}}
      end
    end)
  end

  @doc """
  Walks a source query in pages, gathering what an examination finds.

  The verification counterpart of `page/5`: same keyset paging, but nothing is
  written and the caller accumulates rather than mapping. Returns how many rows
  were looked at and everything the examination returned.
  """
  @spec scan(keyword(), String.t(), ([map()] -> [term()])) :: {non_neg_integer(), [term()]}
  def scan(opts, sql, examine) do
    paged = """
    SELECT * FROM (#{sql}) AS source
    WHERE source.id > $1
    ORDER BY source.id ASC
    LIMIT #{@batch}
    """

    do_scan(opts, paged, examine, 0, 0, [])
  end

  defp do_scan(opts, sql, examine, last_id, checked, found) do
    case Source.rows(opts, sql, [last_id]) do
      {:ok, []} ->
        {checked, Enum.reverse(found)}

      {:ok, rows} ->
        highest = rows |> List.last() |> Map.fetch!("id")

        do_scan(
          opts,
          sql,
          examine,
          highest,
          checked + length(rows),
          Enum.reverse(examine.(rows)) ++ found
        )

      {:error, _unreadable} ->
        {checked, Enum.reverse(found)}
    end
  end

  @doc """
  The name a part's checkpoint is filed under.
  """
  @spec step_name(atom() | String.t(), atom() | String.t()) :: String.t()
  def step_name(step, part), do: "#{step}/#{part}"

  @doc """
  Stops at the first row that could not be mapped, rather than mapping the rest
  of the page and looking for the failure afterwards.
  """
  @spec first_error([map() | nil | {:error, term()}]) :: {:ok, [map()]} | {:error, term()}
  def first_error(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      {:error, reason}, _acc -> {:halt, {:error, reason}}
      nil, acc -> {:cont, acc}
      row, {:ok, acc} -> {:cont, {:ok, [row | acc]}}
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  # The rows and the mark that accounts for them, together or not at all.
  defp write(schema, rows, step, highest) do
    {:ok, _done} =
      Repo.transaction(fn ->
        Repo.insert_all(schema, rows, on_conflict: :nothing)
        Checkpoint.record(step, highest, length(rows))
      end)

    :ok
  end

  defp do_page(opts, step, schema, sql, builder, last_id) do
    case Source.rows(opts, sql, [last_id]) do
      {:ok, []} ->
        Checkpoint.finish(step)

      {:ok, source_rows} ->
        with {:ok, target_rows} <- builder.(source_rows) do
          # The last of an ascending page, rather than a second pass looking
          # for the maximum of something the query already ordered.
          highest = source_rows |> List.last() |> Map.fetch!("id")

          write(schema, target_rows, step, highest)
          do_page(opts, step, schema, sql, builder, highest)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
