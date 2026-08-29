defmodule Abuuba.Repo.Migrations.CreateImportCheckpoints do
  use Ecto.Migration

  @moduledoc """
  How far an import got, so it can be started again rather than started over.

  A takeover moves millions of rows across a network. It will be interrupted:
  by a timeout, by an admin's laptop closing, by a bad row in the middle of a
  batch. Without a record of the last id that landed, every interruption means
  beginning again, and an import nobody dares restart is one that gets left
  half done.

  One row per step, holding the id it reached. The step is the key rather than
  a run id, because a second attempt is a continuation of the same import and
  not a new one; treating it as new is what produces two copies of everything
  up to the point of the first failure.
  """

  def change do
    create table(:import_checkpoints, primary_key: false) do
      add :step, :string, primary_key: true
      # The last source id that was written here. Null before the step starts.
      add :last_id, :bigint
      add :rows, :bigint, null: false, default: 0
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end
  end
end
