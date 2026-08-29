defmodule Abuuba.Repo.Migrations.CreateArchiveImports do
  use Ecto.Migration

  @moduledoc """
  Somebody's own archive, being read back in.

  ## Why there is a row at all

  An archive is a zip of somebody's whole posting history, and reading it takes
  minutes rather than milliseconds. That makes it a job, and a job that nobody
  can see the state of is one they will start again, and again, because nothing
  told them the first one was still going.

  So the row is the thing the settings page reads: how far it has got, what it
  could not do, and whether it is finished. It outlives the request that
  started it and the browser tab that watched it.

  ## Failures are kept, not counted

  "Seventeen posts could not be imported" is not something anybody can act on.
  Which ones, and why, is. They go in a list on the row rather than a table of
  their own: they are read once, by one person, next to the import they belong
  to, and they die with it.

  ## One at a time

  A partial unique index allows a single unfinished import per account. Two at
  once would race over the same statuses and neither progress bar would mean
  anything.
  """

  def change do
    create table(:archive_imports) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :state, :string, null: false, default: "pending"
      add :filename, :string
      # Where the uploaded file is until the job has read it. Removed as soon
      # as it has, because it is a copy of everything somebody ever posted.
      add :path, :string

      add :total, :integer, null: false, default: 0
      add :done, :integer, null: false, default: 0
      add :imported, :integer, null: false, default: 0

      add :failures, :map, null: false, default: fragment("'[]'::jsonb")
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:archive_imports, [:account_id])

    create unique_index(:archive_imports, [:account_id],
             where: "finished_at IS NULL",
             name: :archive_imports_one_running_per_account
           )
  end
end
