defmodule Abuuba.Repo.Migrations.AddAccountModerationNote do
  @moduledoc """
  What one moderator wants the next one to know about an account.

  Not a strike and not a warning: nobody is told, nothing is applied, and the
  account's owner never sees it. It is the place for "this is the third report
  about the same joke" or "spoke to them, they understood" — the context that
  otherwise lives in one person's head and leaves when they do.
  """

  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :moderation_note, :text
    end
  end
end
