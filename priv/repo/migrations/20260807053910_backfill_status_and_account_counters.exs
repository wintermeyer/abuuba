defmodule Abuuba.Repo.Migrations.BackfillStatusAndAccountCounters do
  @moduledoc """
  Fills `status_stats` and `account_stats` from the rows they count.

  These two tables became caches rather than derived-on-read numbers, and the
  code that maintains them only ever moves them by one. Every post, boost,
  reply, favourite and follow already on disk therefore has an increment that
  never happened, and the matching decrement still fires: deleting a post made
  before the change drove `statuses_count` to -1 and Postgres rejected the
  whole delete against `account_stats_counts_are_not_negative`, so the post
  came back and the API answered 500. Unfavouriting an old favourite failed
  the same way. Everything old also rendered every count as zero.

  The predicates below mirror `Abuuba.Statuses.count_status/3` exactly, which is
  what makes the numbers agree with what the running code will do to them
  next: direct posts are counted nowhere, replies count only towards public
  and unlisted parents, and a boost counts towards its original unless it is
  direct.

  Written as `SET`, not as an increment, so running it twice is the same as
  running it once.
  """

  use Ecto.Migration

  # A backfill reads every status and every favourite. Outside the migration
  # transaction those reads would see rows appear underneath them.
  @disable_ddl_transaction false

  def up do
    execute """
    INSERT INTO status_stats (status_id, replies_count, reblogs_count, favourites_count,
                              inserted_at, updated_at)
    SELECT s.id,
           coalesce(r.replies, 0),
           coalesce(b.boosts, 0),
           coalesce(f.marks, 0),
           now(), now()
    FROM statuses s
    LEFT JOIN (
      SELECT in_reply_to_id AS id, count(*) AS replies
      FROM statuses
      WHERE deleted_at IS NULL AND in_reply_to_id IS NOT NULL
        AND visibility IN ('public', 'unlisted')
      GROUP BY in_reply_to_id
    ) r ON r.id = s.id
    LEFT JOIN (
      SELECT reblog_of_id AS id, count(*) AS boosts
      FROM statuses
      WHERE deleted_at IS NULL AND reblog_of_id IS NOT NULL AND visibility <> 'direct'
      GROUP BY reblog_of_id
    ) b ON b.id = s.id
    LEFT JOIN (
      SELECT status_id AS id, count(*) AS marks FROM favourites GROUP BY status_id
    ) f ON f.id = s.id
    WHERE s.deleted_at IS NULL
      AND (r.replies IS NOT NULL OR b.boosts IS NOT NULL OR f.marks IS NOT NULL)
    ON CONFLICT (status_id) DO UPDATE
      SET replies_count = EXCLUDED.replies_count,
          reblogs_count = EXCLUDED.reblogs_count,
          favourites_count = EXCLUDED.favourites_count,
          updated_at = now()
    """

    execute """
    INSERT INTO account_stats (account_id, statuses_count, following_count, followers_count,
                               last_status_at, inserted_at, updated_at)
    SELECT a.id,
           coalesce(p.posts, 0),
           coalesce(g.following, 0),
           coalesce(w.followers, 0),
           p.last_at,
           now(), now()
    FROM accounts a
    LEFT JOIN (
      SELECT account_id, count(*) AS posts, max(inserted_at) AS last_at
      FROM statuses
      WHERE deleted_at IS NULL AND visibility <> 'direct'
      GROUP BY account_id
    ) p ON p.account_id = a.id
    LEFT JOIN (
      SELECT account_id, count(*) AS following FROM follows GROUP BY account_id
    ) g ON g.account_id = a.id
    LEFT JOIN (
      SELECT target_account_id AS account_id, count(*) AS followers
      FROM follows GROUP BY target_account_id
    ) w ON w.account_id = a.id
    WHERE p.posts IS NOT NULL OR g.following IS NOT NULL OR w.followers IS NOT NULL
    ON CONFLICT (account_id) DO UPDATE
      SET statuses_count = EXCLUDED.statuses_count,
          following_count = EXCLUDED.following_count,
          followers_count = EXCLUDED.followers_count,
          last_status_at = EXCLUDED.last_status_at,
          updated_at = now()
    """
  end

  # Recomputing from the same rows is what `up` does, so there is nothing to
  # undo: throwing the counters away would leave the running code worse off
  # than it found them.
  def down, do: :ok
end
