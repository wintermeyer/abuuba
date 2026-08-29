defmodule Abuuba.Importer.Checkpoint do
  @moduledoc """
  How far each step of an import got.

  A takeover moves millions of rows and will be interrupted: by a timeout, by a
  laptop closing, by one bad row in the middle of a batch. Without a mark, every
  interruption means starting over, and an import nobody dares restart is one
  that gets left half done.

  The mark only ever moves forward. A batch that finishes out of order must not
  rewind it, because everything after the lower mark would then be copied a
  second time.
  """

  import Ecto.Query

  alias Abuuba.Repo

  @doc """
  The last source id a step reached, or `nil`.
  """
  @spec last_id(String.t()) :: integer() | nil
  def last_id(step) do
    from(c in "import_checkpoints", where: c.step == ^step, select: c.last_id) |> Repo.one()
  end

  @doc """
  How many rows a step has written.
  """
  @spec rows(String.t()) :: integer()
  def rows(step) do
    from(c in "import_checkpoints", where: c.step == ^step, select: c.rows)
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc """
  Whether a step has finished, so a rerun can skip it.
  """
  @spec finished?(String.t()) :: boolean()
  def finished?(step) do
    from(c in "import_checkpoints", where: c.step == ^step, select: not is_nil(c.finished_at))
    |> Repo.one()
    |> Kernel.||(false)
  end

  @doc """
  Records that a step reached an id, having written some rows.
  """
  @spec record(String.t(), integer(), integer()) :: :ok
  def record(step, last_id, rows) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "import_checkpoints",
      [[step: step, last_id: last_id, rows: rows, inserted_at: now, updated_at: now]],
      conflict_target: [:step],
      on_conflict:
        from(c in "import_checkpoints",
          update: [
            # `greatest` rather than an assignment: the mark only moves forward.
            set: [last_id: fragment("greatest(?, ?)", c.last_id, ^last_id), updated_at: ^now],
            inc: [rows: ^rows]
          ]
        )
    )

    :ok
  end

  @doc """
  Marks a step finished.
  """
  @spec finish(String.t()) :: :ok
  def finish(step) do
    now = DateTime.utc_now()

    {count, _} =
      from(c in "import_checkpoints", where: c.step == ^step)
      |> Repo.update_all(set: [finished_at: now, updated_at: now])

    if count == 0 do
      Repo.insert_all("import_checkpoints", [
        [step: step, rows: 0, finished_at: now, inserted_at: now, updated_at: now]
      ])
    end

    :ok
  end

  @doc """
  Forgets everything, for an import somebody means to redo from the start.
  """
  @spec reset() :: :ok
  def reset do
    Repo.delete_all("import_checkpoints")

    :ok
  end

  @doc """
  What every step has reached, for a report.
  """
  @spec all() :: [map()]
  def all do
    from(c in "import_checkpoints",
      order_by: [asc: c.step],
      select: %{
        step: c.step,
        last_id: c.last_id,
        rows: c.rows,
        finished_at: c.finished_at
      }
    )
    |> Repo.all()
  end
end
