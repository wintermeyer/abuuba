defmodule Abuuba.Repo.Migrations.CreateStrikesAndNotes do
  use Ecto.Migration

  @moduledoc """
  What was done to an account, why, and what they can say about it.

  ## A strike is the record the account's owner reads

  The audit log is what moderators read about each other. A strike is what the
  person on the receiving end reads about themselves: what was decided, when,
  which of their posts it was about, and what they were told. Without it the
  answer to "why can nobody see my posts" is nothing at all.

  ## Appeals have a window

  Twenty days. Long enough that somebody who was away can still answer, short
  enough that a moderator is not asked to reconstruct a decision from months
  ago against evidence that has since been deleted.

  ## Notes are moderators talking to each other

  Never shown to the account. A note is "we have seen this pattern before" or
  "the report last month was the same person", which is exactly the sort of
  thing that has to be written down and exactly the sort of thing that must not
  be handed to whoever it is about.
  """

  def change do
    create table(:account_warnings) do
      # Who decided. Null when the account is gone rather than the decision.
      add :account_id, references(:accounts, type: :bigint, on_delete: :nilify_all)

      add :target_account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false

      add :action, :string, null: false, default: "none"
      add :text, :text, null: false, default: ""

      # The posts the decision was about, so somebody reading their strike can
      # see which ones rather than guessing.
      add :status_ids, {:array, :bigint}, null: false, default: []

      add :report_id, references(:reports, on_delete: :nilify_all)

      # When the account may stop being told about it. Null means it stands.
      add :overruled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:account_warnings, :account_warnings_action_known,
             check:
               "action in ('none', 'disable', 'mark_statuses_as_sensitive', 'delete_statuses', 'silence', 'suspend')"
           )

    create index(:account_warnings, [:target_account_id, :id])
    create index(:account_warnings, [:report_id])

    create table(:appeals) do
      add :account_warning_id, references(:account_warnings, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :text, :text, null: false, default: ""

      add :approved_at, :utc_datetime_usec
      add :rejected_at, :utc_datetime_usec

      add :approved_by_account_id, references(:accounts, type: :bigint, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    # One appeal per strike. Somebody who can appeal twice can appeal until a
    # different moderator happens to be reading.
    create unique_index(:appeals, [:account_warning_id])
    create index(:appeals, [:approved_at, :rejected_at])

    create table(:moderation_notes) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :nilify_all), null: false

      # What the note is about: an account or a report.
      add :target_type, :string, null: false
      add :target_id, :bigint, null: false

      add :content, :text, null: false, default: ""

      timestamps(type: :utc_datetime_usec)
    end

    create index(:moderation_notes, [:target_type, :target_id, :id])

    alter table(:accounts) do
      # When a suspension began purging. A suspended account's content is kept
      # for a grace window first, because a suspension reversed on appeal has
      # to be able to give it back.
      add :purge_after, :utc_datetime_usec
    end
  end
end
