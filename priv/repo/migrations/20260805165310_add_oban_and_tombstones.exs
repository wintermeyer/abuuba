defmodule Abuuba.Repo.Migrations.AddObanAndTombstones do
  @moduledoc """
  Oban's tables, and the record of things we have already been told are gone.

  A `Delete` is redelivered constantly: the sending server retries, several of
  our users may share an inbox, and a relay may repeat it. Each redelivery
  would otherwise mean a fetch for an object that no longer exists, which is a
  request to a server that has already told us the answer.

  Keyed by the object's URI rather than by anything local, because the whole
  point is to recognise a delete for something we may never have held.
  """
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 14)

    create table(:tombstones, primary_key: false) do
      add :uri, :text, primary_key: true
      add :kind, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:tombstones, [:inserted_at])
  end

  def down do
    drop table(:tombstones)

    Oban.Migration.down(version: 1)
  end
end
