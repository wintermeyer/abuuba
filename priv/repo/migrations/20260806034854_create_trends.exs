defmodule Abuuba.Repo.Migrations.CreateTrends do
  use Ecto.Migration

  @moduledoc """
  What is being used, how much, and what a moderator has said about it.

  ## Counted in Postgres, per day, per subject

  Two tables rather than a counting service: `trend_counters` holds the numbers,
  and `trend_participants` holds one narrow row per account that used a subject
  that day, purely to answer "have we already counted this person today".
  Unique accounts is what the score is actually about, because one person
  posting a tag two hundred times is not a trend, and counting distinct people
  exactly costs one row each rather than an approximation nobody can audit
  afterwards.

  Rows are per day and swept, so the tables stay the size of what is happening
  now rather than of everything that ever happened.

  ## Rankings are recomputed, not maintained

  `trends` is rewritten every few minutes. Keeping a running rank correct under
  concurrent writes is far harder than recomputing a few hundred rows, and a
  rank five minutes stale is not a problem anybody has.

  ## Reviewed before it is shown

  Every kind carries `trendable` as a **nullable** boolean: null means nobody
  has looked yet, and what null means in practice is the `trendable_by_default`
  setting's business. A trending list is the most prominent place on a server,
  and handing it to whatever an anonymous crowd pushed hardest is how it
  becomes a megaphone for the thing being pushed.
  """

  def change do
    create table(:trend_counters) do
      add :kind, :string, null: false
      add :subject, :string, null: false
      add :day, :date, null: false
      add :uses, :integer, null: false, default: 0
      # How many distinct accounts, kept as a column rather than counted from
      # `trend_participants` at ranking time. That table exists to answer "have
      # we already counted this person today"; the number itself is read on
      # every recompute and belongs where it can be read without a group-by.
      add :accounts, :integer, null: false, default: 0
      # Kept so a language-partitioned ranking does not have to join back to
      # the statuses the counts came from.
      add :language, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:trend_counters, [:kind, :subject, :day])
    create index(:trend_counters, [:day])

    create table(:trend_participants, primary_key: false) do
      add :kind, :string, null: false, primary_key: true
      add :subject, :string, null: false, primary_key: true
      add :day, :date, null: false, primary_key: true

      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true
    end

    create index(:trend_participants, [:day])

    create table(:trends) do
      add :kind, :string, null: false
      add :subject, :string, null: false
      # Null is "no language in particular", which is where a subject whose
      # posts carry no language belongs rather than being dropped.
      add :language, :string
      add :score, :float, null: false, default: 0.0
      add :rank, :integer, null: false, default: 0
      add :uses, :integer, null: false, default: 0
      add :accounts, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:trends, [:kind, :subject, :language])
    create index(:trends, [:kind, :language, :rank])

    # Links have no home of their own until preview cards land, and trends
    # needs somewhere to record what a moderator decided about one. The row is
    # the decision; the card, when it exists, hangs off the same URL.
    create table(:trend_links) do
      add :url, :text, null: false
      add :provider, :string, null: false
      add :title, :text
      add :trendable, :boolean
      add :reviewed_at, :utc_datetime_usec
      add :requested_review_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:trend_links, [:url])
    create index(:trend_links, [:provider])

    alter table(:tags) do
      add :reviewed_at, :utc_datetime_usec
      add :requested_review_at, :utc_datetime_usec
    end

    # `trendable` was a plain boolean defaulting to true, which cannot say "no
    # moderator has looked at this yet". The three states are the point of a
    # review queue.
    execute "ALTER TABLE tags ALTER COLUMN trendable DROP DEFAULT",
            "ALTER TABLE tags ALTER COLUMN trendable SET DEFAULT true"

    execute "ALTER TABLE tags ALTER COLUMN trendable DROP NOT NULL",
            "ALTER TABLE tags ALTER COLUMN trendable SET NOT NULL"

    execute "UPDATE tags SET trendable = NULL", "UPDATE tags SET trendable = true"

    alter table(:accounts) do
      # Whether this account's posts may appear in trends. Null until somebody
      # decides, the same three states as everything else here.
      add :trendable, :boolean
    end
  end
end
