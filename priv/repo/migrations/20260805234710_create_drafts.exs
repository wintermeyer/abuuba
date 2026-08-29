defmodule Abuuba.Repo.Migrations.CreateDrafts do
  use Ecto.Migration

  import Abuuba.Snowflake.Migration

  @moduledoc """
  A post somebody started and has not sent.

  Kept as the composer's own state rather than as an unpublished status row,
  for the same reason a scheduled post is: an unsent post filed among the sent
  ones is one that the first query which forgets to exclude it will publish.

  Nothing here is ever federated or shown to anybody else, so there is no URI,
  no visibility to enforce and no counter to keep. It is a piece of paper on
  somebody's own desk.
  """

  def change do
    create table(:drafts, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false
      add :params, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:drafts)

    # The list is always one account's, newest first.
    create index(:drafts, [:account_id, :updated_at])
  end
end
