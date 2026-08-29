defmodule Abuuba.Repo.Migrations.CreateSuggestionDismissals do
  @moduledoc """
  Who somebody has told us to stop suggesting.

  A suggestion is computed rather than stored — it is whoever the people you
  follow follow — so it comes back on every request unless the "not this one"
  is remembered. Without this table the dismiss button clears the card and the
  same person is back the next time the column loads, which reads as the button
  being broken.
  """

  use Ecto.Migration

  def change do
    create table(:suggestion_dismissals) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :target_account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:suggestion_dismissals, [:account_id, :target_account_id])
  end
end
