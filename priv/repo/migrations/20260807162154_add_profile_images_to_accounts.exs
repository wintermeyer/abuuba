defmodule Abuuba.Repo.Migrations.AddProfileImagesToAccounts do
  use Ecto.Migration

  @moduledoc """
  An account's avatar and header.

  Columns on `accounts` rather than rows in `media_attachments`, which is the
  shape the reference implementation uses and the shape an importer taking over
  one of its databases will hand us. They also behave differently from an
  attachment: there is exactly one of each per account, it is replaced rather
  than added to, and it is read on every render of every post that account
  wrote, which is not something to reach a second table for.

  `*_remote_url` holds where somebody else's picture lives. For an account on
  this server it stays null: what is served is what was uploaded.
  """

  def change do
    alter table(:accounts) do
      add :avatar_file_name, :string
      add :avatar_content_type, :string
      add :avatar_file_size, :integer
      add :avatar_updated_at, :utc_datetime_usec
      add :avatar_remote_url, :text

      add :header_file_name, :string
      add :header_content_type, :string
      add :header_file_size, :integer
      add :header_updated_at, :utc_datetime_usec
      add :header_remote_url, :text
    end
  end
end
