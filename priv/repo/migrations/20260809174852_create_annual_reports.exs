defmodule Abuuba.Repo.Migrations.CreateAnnualReports do
  @moduledoc """
  Somebody's year on this server, worked out once and kept.

  Generated rather than computed on request: the queries walk a year of
  somebody's posts, and a page that recomputed them on every load would be the
  most expensive screen on the server during precisely the fortnight everybody
  opens it.

  `data` is the whole report as one document. The shape belongs to the version
  that wrote it, which is what `schema_version` is for: a report generated last
  year is not re-run when the shape changes, it is read with the reader that
  understands it, or ignored.
  """

  use Ecto.Migration

  def change do
    create table(:annual_reports) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false
      add :year, :integer, null: false
      add :data, :map, null: false, default: fragment("'{}'::jsonb")
      add :schema_version, :integer, null: false, default: 1

      # When its owner looked. Null is "we have not told them yet" as far as
      # the client is concerned, and it is what the unread badge reads.
      add :viewed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # One per person per year. Generating twice is generating once.
    create unique_index(:annual_reports, [:account_id, :year])
  end
end
