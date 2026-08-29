defmodule Abuuba.Repo.Migrations.CreateMarkers do
  @moduledoc """
  Where somebody had read up to, per timeline.

  A person reads on their phone and picks up on a laptop, and without this the
  second one starts at the top with no idea what the first had already seen.

  The version column is what makes two clients writing at once safe. Both hold
  a marker, both move it, and last-write-wins would silently move somebody's
  place backwards to whatever the slower device thought. Instead the second
  write is refused and the client is told to re-read.
  """
  use Ecto.Migration

  def change do
    create table(:markers, primary_key: false) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true

      # "home" or "notifications". A string rather than an enum because the set
      # is the client API's, not ours, and a new one arriving should not need a
      # migration to be stored.
      add :timeline, :string, null: false, primary_key: true

      add :last_read_id, :bigint, null: false
      add :version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end
  end
end
