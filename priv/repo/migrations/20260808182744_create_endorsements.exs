defmodule Abuuba.Repo.Migrations.CreateEndorsements do
  @moduledoc """
  Accounts somebody has put on their own profile as worth following.

  The reference implementation calls the row an `account_pin` and the API calls
  the act "endorse" in one place and "pin" in another; the table is named after
  what it means rather than after either spelling, because nothing outside this
  server sees the name.

  Both sides cascade. An endorsement is a statement one account makes about
  another, and it stops meaning anything the moment either of them is gone.
  """

  use Ecto.Migration

  def change do
    create table(:endorsements) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :target_account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Endorsing somebody twice is endorsing them once, and the unique index is
    # what lets the write be an upsert rather than a read followed by a write
    # that two requests can both pass.
    create unique_index(:endorsements, [:account_id, :target_account_id])

    # Reading somebody else's endorsements is reading by the target, which the
    # index above cannot serve.
    create index(:endorsements, [:target_account_id])
  end
end
