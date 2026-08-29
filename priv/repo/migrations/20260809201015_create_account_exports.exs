defmodule Abuuba.Repo.Migrations.CreateAccountExports do
  @moduledoc """
  A copy of somebody's own account, built once and kept for a while.

  The mirror image of `account_imports`, and shaped like it on purpose: the two
  screens sit next to each other and somebody watching one should recognise the
  other. Building an archive walks every post, every attachment record and
  every list somebody has, so it is a job with a row rather than a download
  that holds a request open for a minute.
  """

  use Ecto.Migration

  def change do
    create table(:account_exports) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :state, :string, null: false, default: "pending"
      add :path, :string
      add :filename, :string
      add :size, :bigint
      add :error, :string

      # When the file stops being downloadable and the sweeper may take it. An
      # archive is the most sensitive single object this server ever writes —
      # somebody's whole account in one file — so it expires rather than
      # sitting on disk until an admin thinks to look.
      add :expires_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:account_exports, [:account_id, :id])
    create index(:account_exports, [:expires_at])
  end
end
