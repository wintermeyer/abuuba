defmodule Abuuba.Repo.Migrations.CreateFeedEntries do
  use Ecto.Migration

  @moduledoc """
  One row per post per feed it belongs in.

  ## Why a table rather than a query

  A home timeline is "everything by everybody I follow, minus what I have
  filtered out", and asking that question at read time means a join against the
  follow graph on every scroll, for every reader, forever. Writing the answer
  once when a post is made turns every read into an index scan over one
  account's rows.

  ## Three columns and no more

  The status id is a snowflake, so it is the timestamp, the sort key and the
  pagination cursor all at once. A created_at column would be the same
  information stored twice, and this is the table that grows fastest.

  ## The primary key is the read

  `(feed_type, feed_id, status_id DESC)` is exactly the shape of every query
  against it: one feed, newest first, seek by cursor. Postgres reads it
  backwards perfectly well, but stating the order makes the index match the
  scan without a sort node, and it doubles as the uniqueness that makes a
  re-run of a fan-out job harmless.
  """

  def change do
    create table(:feed_entries, primary_key: false) do
      # `home` or `list`, and the id of whichever it is. Two feeds in one table
      # because the writing, the trimming and the reading are identical, and a
      # second table would be the same code twice.
      add :feed_type, :string, null: false
      add :feed_id, :bigint, null: false
      add :status_id, :bigint, null: false
    end

    execute(
      "ALTER TABLE feed_entries ADD CONSTRAINT feed_entries_pkey PRIMARY KEY (feed_type, feed_id, status_id)",
      "ALTER TABLE feed_entries DROP CONSTRAINT feed_entries_pkey"
    )

    create index(:feed_entries, [:feed_type, :feed_id, "status_id DESC"],
             name: :feed_entries_reading_index
           )

    # Deleting a post has to clear it from every feed it reached, and that is
    # the one query that is not by feed.
    create index(:feed_entries, [:status_id])

    alter table(:users) do
      # What "active" means for fan-out. A feed written for somebody who has
      # not opened the place in a year is rows nobody will ever read, and the
      # work of writing them is paid on every post.
      add :last_signed_in_at, :utc_datetime_usec
    end

    create index(:users, [:last_signed_in_at])
  end
end
