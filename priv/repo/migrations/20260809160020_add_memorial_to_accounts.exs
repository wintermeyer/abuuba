defmodule Abuuba.Repo.Migrations.AddMemorialToAccounts do
  @moduledoc """
  An account whose owner has died.

  Different from every other state on the moderation ladder, and the difference
  is the point: nothing is hidden, nothing is taken down, and nobody can sign
  in. The posts stay where they are and stay readable, because that is what the
  people who knew them want; what stops is the account being used.

  A column rather than a suspension with a note, because clients render it
  differently — a memorial profile is marked as one rather than shown as
  missing — and because a suspension is a judgement about somebody's conduct.
  """

  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :memorial, :boolean, null: false, default: false
    end
  end
end
