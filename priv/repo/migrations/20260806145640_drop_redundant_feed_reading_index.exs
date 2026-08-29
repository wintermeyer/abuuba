defmodule Abuuba.Repo.Migrations.DropRedundantFeedReadingIndex do
  @moduledoc """
  Drops `feed_entries_reading_index`, which the primary key already covers.

  The table carried two indexes over the same three columns in the same order:

      feed_entries_pkey           (feed_type, feed_id, status_id)
      feed_entries_reading_index  (feed_type, feed_id, status_id DESC)

  A btree can be walked in either direction, so the descending copy buys
  nothing the primary key does not already provide. Measured against a feed of
  200,200 rows, the hot timeline read is the same query either way:

      with it     Index Scan using feed_entries_reading_index    0.266 ms
      without it  Index Scan Backward using feed_entries_pkey    0.294 ms

  The difference is inside the noise, and the index cost 9320 kB against the
  primary key's 9312 kB. What it did cost is writes: a feed row is written once
  per follower per post, the highest-volume insert there is here, and every one
  of them maintained two identical trees.
  """

  use Ecto.Migration

  def up do
    drop_if_exists index(:feed_entries, [:feed_type, :feed_id, :status_id],
                     name: :feed_entries_reading_index
                   )
  end

  def down do
    create_if_not_exists index(:feed_entries, [:feed_type, :feed_id, "status_id DESC"],
                           name: :feed_entries_reading_index
                         )
  end
end
