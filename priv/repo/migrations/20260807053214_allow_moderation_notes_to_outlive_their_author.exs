defmodule Abuuba.Repo.Migrations.AllowModerationNotesToOutliveTheirAuthor do
  @moduledoc """
  `moderation_notes.account_id` was `null: false` behind a foreign key
  declared `on_delete: :nilify_all`, which is a rule that cannot be obeyed:
  deleting the moderator who wrote a note made Postgres try to write the NULL
  the column forbids, and the whole delete failed with a 23502. Any moderator
  who had ever written a note could not be removed, by an admin, by a purge,
  or by a federated Delete.

  The column becomes nullable, which is what `nilify_all` said the intent was.
  A note is moderation history worth more than the name attached to it: it
  survives its author and reads as written by nobody in particular, the same
  way the audit log outlives the accounts it describes.
  """

  use Ecto.Migration

  def up do
    alter table(:moderation_notes) do
      modify :account_id, :bigint, null: true
    end
  end

  def down do
    # Rows whose author has since been deleted have no name to restore, so the
    # constraint can only come back after they are gone.
    execute "DELETE FROM moderation_notes WHERE account_id IS NULL"

    alter table(:moderation_notes) do
      modify :account_id, :bigint, null: false
    end
  end
end
