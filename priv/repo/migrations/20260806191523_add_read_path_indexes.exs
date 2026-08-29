defmodule Abuuba.Repo.Migrations.AddReadPathIndexes do
  @moduledoc """
  Indexes for the read paths that had none, and one whose column order was
  backwards for the queries that use it.

  `statuses_tags` was indexed `(tag_id, status_id)` only, which serves a tag
  timeline and nothing else: rendering a page of posts asks "which tags does
  this status carry", and excluding tags from a timeline probes by status too.
  Both were sequential scans. The reverse order joins the existing index
  rather than replacing it, because the tag timeline still wants its own.

  `favourites (status_id, account_id)` replaces the single-column index: who
  favourited a post is listed newest-account-first, and the composite serves
  the sort straight off the index instead of fetching every favourite the
  post ever got and sorting them. The boost twin on `statuses` does the same
  for who boosted it.

  The rest are foreign keys toward `statuses` and `conversations` that had no
  leading index at all, so a hard delete — account purges do this — was a
  sequential scan per table. And `accounts` gets the partial index the
  directory reads, whose query previously walked the whole primary key
  backwards looking for the few rows that are discoverable.
  """

  use Ecto.Migration

  def change do
    create index(:statuses_tags, [:status_id, :tag_id])

    create index(:favourites, [:status_id, :account_id])
    drop index(:favourites, [:status_id])

    create index(:statuses, [:reblog_of_id, :account_id],
             where: "reblog_of_id IS NOT NULL AND deleted_at IS NULL",
             name: :statuses_boosted_by_index
           )

    create index(:bookmarks, [:status_id])
    create index(:status_pins, [:status_id])
    create index(:filter_statuses, [:status_id])
    create index(:conversation_mutes, [:conversation_id])

    create index(:accounts, ["id DESC"],
             where: "discoverable AND domain IS NULL AND suspended_at IS NULL",
             name: :accounts_directory_index
           )

    # Deleting a post promotes whoever stood hidden behind it, in every feed
    # at once, by probing `hidden_by_status_id` alone — the existing hidden
    # index leads with the feed and cannot serve that.
    create index(:feed_entries, [:hidden_by_status_id], where: "hidden_by_status_id IS NOT NULL")
  end
end
