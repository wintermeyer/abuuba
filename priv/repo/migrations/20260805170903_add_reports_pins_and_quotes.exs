defmodule Abuuba.Repo.Migrations.AddReportsPinsAndQuotes do
  @moduledoc """
  What the remaining inbound activities need somewhere to go.

  `reports` is the minimum a `Flag` needs to land in. The moderation pipeline
  around it is its own issue; this is the row that pipeline will read.

  `featured_tags` is half of the featured collection, which peers edit with
  `Add` and `Remove`. The other half, `status_pins`, is created by the later
  migration that gives it timestamp ids along with the rest of the posting
  tables; creating it here as well left a fresh database stopping on whichever
  came second.

  `quotes` records one post quoting another and, crucially, whether the quoted
  author agreed. A quote is a republication of somebody else's words next to
  commentary they did not choose, so consent is the whole point of FEP-044f and
  the approval URI is the evidence of it.

  `moved_at` on accounts enforces the migration cooldown. Moving repeatedly is
  how somebody drags a follower list around the network faster than anybody can
  notice.
  """
  use Ecto.Migration

  def change do
    create table(:reports) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :nilify_all)

      add :target_account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false

      add :comment, :text, null: false, default: ""
      add :uri, :text
      add :forwarded, :boolean, null: false, default: false

      # The posts the report is about. An array rather than a join table: a
      # report names them once and never edits the list.
      add :status_ids, {:array, :bigint}, null: false, default: []

      add :action_taken_at, :utc_datetime_usec

      add :action_taken_by_account_id,
          references(:accounts, type: :bigint, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:reports, [:target_account_id])
    create unique_index(:reports, [:uri])
    create index(:reports, [:action_taken_at], where: "action_taken_at IS NULL")

    create table(:featured_tags) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false
      add :tag_id, references(:tags, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:featured_tags, [:account_id, :tag_id])

    create table(:quotes) do
      add :status_id, references(:statuses, type: :bigint, on_delete: :delete_all), null: false

      # Null while we hold only the URI of something we have not fetched.
      add :quoted_status_id, references(:statuses, type: :bigint, on_delete: :nilify_all)
      add :quoted_status_uri, :text, null: false

      # The QuoteAuthorization the quoted author issued. Its absence is what
      # makes a quote unapproved rather than a field being blank.
      add :approval_uri, :text

      add :state, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:quotes, [:status_id])
    create index(:quotes, [:quoted_status_id])

    create constraint(:quotes, :quotes_state_known,
             check: "state IN ('pending', 'accepted', 'rejected', 'revoked')"
           )

    alter table(:accounts) do
      add :moved_at, :utc_datetime_usec
    end
  end
end
