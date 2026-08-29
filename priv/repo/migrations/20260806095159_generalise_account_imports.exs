defmodule Abuuba.Repo.Migrations.GeneraliseAccountImports do
  use Ecto.Migration

  @moduledoc """
  One table for everything somebody imports into their own account.

  The archive import arrived first and got a table of its own. The CSV imports
  that follow — follows, blocks, mutes, lists, bookmarks, domain blocks,
  filters — want exactly the same row: whose it is, how far it has got, what it
  could not do, and whether it is finished. A second table would mean a second
  progress bar, a second failure list and a second settings panel that has to
  be kept in step with the first.

  So the table says what kind of import it is, and everything around it stops
  caring.

  ## Two new columns

  `kind` is what is being read. `mode` is what to do with what is already
  there: merge adds to it, overwrite replaces it. The second one only means
  anything for the list-shaped imports, and it is the difference between "here
  are twelve more people I follow" and "this is now everybody I follow".
  """

  def change do
    rename table(:archive_imports), to: table(:account_imports)

    alter table(:account_imports) do
      add :kind, :string, null: false, default: "archive"
      add :mode, :string, null: false, default: "merge"
    end

    execute "ALTER INDEX archive_imports_one_running_per_account RENAME TO account_imports_one_running_per_account",
            "ALTER INDEX account_imports_one_running_per_account RENAME TO archive_imports_one_running_per_account"

    execute "ALTER INDEX archive_imports_account_id_index RENAME TO account_imports_account_id_index",
            "ALTER INDEX account_imports_account_id_index RENAME TO archive_imports_account_id_index"
  end
end
