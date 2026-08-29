defmodule Abuuba.Repo.Migrations.ExtendReportsAndAddAuditLog do
  use Ecto.Migration

  @moduledoc """
  What a report says it is about, who is dealing with it, and what was done.

  ## The category is what a moderator sorts by

  "Spam", "breaks a rule", "illegal", "something else". Without it every report
  is a paragraph somebody has to read before they can decide whether it is
  urgent, and a queue of a hundred is a hundred paragraphs.

  A rule-breaking report names which rules, so the queue can say "rule 3" and
  the person who wrote rule 3 can find every report about it.

  ## Assignment is how two moderators avoid doing the same work

  One column. Without it, a busy queue is two people opening the same report
  and reaching two different decisions.

  ## The audit log is the answer to "why is this account suspended"

  Every moderation action writes a row naming who did it, to what, and when. It
  is not a debugging aid: it is what one moderator reads to understand what
  another already decided, and what an appeal is judged against.
  """

  def change do
    alter table(:reports) do
      # Mastodon's four, so a client that files a report against one server can
      # file the same one here.
      add :category, :string, null: false, default: "other"

      # Which rules a "breaks a rule" report names.
      add :rule_ids, {:array, :bigint}, null: false, default: []

      add :assigned_account_id,
          references(:accounts, type: :bigint, on_delete: :nilify_all)
    end

    create constraint(:reports, :reports_category_known,
             check: "category in ('other', 'spam', 'legal', 'violation')"
           )

    create index(:reports, [:assigned_account_id])
    # The queue: unresolved first, newest first, which is one index.
    create index(:reports, [:action_taken_at, :id])

    create table(:audit_log_entries) do
      # Who did it. Null for something the server did on its own, which is rare
      # and worth being able to tell apart.
      add :account_id, references(:accounts, type: :bigint, on_delete: :nilify_all)

      # What was done and to what. Free text rather than an enum: the set grows
      # with every moderation feature, and a migration per verb would mean the
      # log lagging behind the actions it records.
      add :action, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :bigint

      # Whatever the action needs remembered, such as the reason given.
      add :details, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # Two reads: everything about one thing, and everything one moderator did.
    create index(:audit_log_entries, [:target_type, :target_id, :id])
    create index(:audit_log_entries, [:account_id, :id])
  end
end
