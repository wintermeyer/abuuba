defmodule Abuuba.Statuses.Prune do
  @moduledoc """
  Removing old posts from elsewhere that nothing here is attached to.

  ## Why a server needs this

  Every post a peer sends is stored, and nothing ever removes one. A server
  that has federated for a year holds millions of posts nobody here will read
  again, and `statuses` is both the largest table and the largest set of
  indexes on the machine. Freeing the images with `mix abuuba.media remove-remote`
  leaves the rows and their text behind, which is most of the size.

  Local posts are never touched. They are this server's own record, other
  servers hold their addresses, and an admin deleting somebody's posts by age
  is not housekeeping.

  ## What counts as attached

  A remote post stays, whatever its age, when anything here points at it:

    * somebody favourited, bookmarked, boosted, replied to, quoted or pinned it
    * it mentions an account here, or a notification refers to it
    * somebody voted in its poll, filtered it, or reported it
    * it is still in a timeline here, or in a conversation an account here is in

  "A timeline here" means one somebody can open: an account on this server or
  one of its lists. `feed_entries` can hold a home-feed row for an account on
  another server, which nobody can open — fan-out wrote one for the author of
  every post it stored until that was fixed, and a server that ran an older
  version has them until the migration that clears them runs. Counting any feed
  row at all would have kept every post ever received and made this a no-op
  that still reported success.

  Those are the posts still reachable from a screen somebody can open. The rest
  are reachable only from a timeline that scrolled past them long ago.

  Direct and limited posts are never removed by age at all. One of those was
  addressed to particular people rather than published, there are few enough of
  them that keeping all of them costs nothing, and removing one by mistake
  takes away somebody's correspondence.

  ## Ancestors, which is the part that is easy to get wrong

  Keeping a post but deleting its parent leaves a thread that cannot be read
  from the top, and `in_reply_to_id` is nulled on delete, so the break is
  silent. The kept set therefore walks upward: every ancestor of a kept post is
  kept too, however old and however untouched, for as many levels as the thread
  has.

  Boosts are walked the same way for a harder reason. `reblog_of_id` deletes on
  cascade, so removing an original silently removes every boost of it. A boost
  that is kept keeps its original.

  Both walks run as one recursive query rather than a loop in Elixir, because
  the number of levels is not known in advance and each round trip would be a
  full pass over the table.

  ## The count and the deletion are the same query

  A dry run that counted differently from the real run would be worse than no
  dry run, because it is a number somebody trusted before pressing return on a
  live server.
  """

  import Ecto.Query

  alias Abuuba.Repo
  alias Abuuba.Statuses.Status

  @doc """
  The moment before which a remote post is a candidate.
  """
  @spec cutoff(pos_integer()) :: DateTime.t()
  def cutoff(days) when is_integer(days) and days > 0,
    do: DateTime.add(DateTime.utc_now(), -days, :day)

  @doc """
  How many posts a run with this cutoff would remove.
  """
  @spec count(DateTime.t()) :: non_neg_integer()
  def count(%DateTime{} = cutoff), do: cutoff |> removable() |> Repo.aggregate(:count)

  @doc """
  The ids it would remove, oldest first.

  Chiefly here so the tests can name a post and ask whether it is in the set;
  `remove/1` does not go through it, because materialising millions of ids to
  hand back to Postgres would be slower than the query it already has.
  """
  @spec removable_ids(DateTime.t()) :: [integer()]
  def removable_ids(%DateTime{} = cutoff) do
    cutoff |> removable() |> select([s], s.id) |> order_by([s], asc: s.id) |> Repo.all()
  end

  @doc """
  Removes them, in one transaction.

  Half a prune is not a broken server — every reference either cascades or is
  nulled — but it is an admin who cannot tell what the number they were shown
  meant.
  """
  @spec remove(DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def remove(%DateTime{} = cutoff) do
    Repo.transaction(
      fn ->
        # Before the posts, because afterwards there is no way to tell which
        # feed rows were theirs. `feed_entries` carries no foreign key — it is
        # denormalised on purpose, and the price is that deletes are ours to
        # follow through by hand.
        drop_feed_rows(cutoff)

        {removed, _returned} = cutoff |> removable() |> Repo.delete_all(timeout: :infinity)

        removed
      end,
      timeout: :infinity
    )
  end

  @doc """
  What the remote posts are costing, and what a cutoff would recover.

  The share of rows rather than of bytes: a table's size is not divisible by
  row, and multiplying an average row width by a count would be a made-up
  number printed next to a real one.
  """
  @spec usage(DateTime.t() | nil) :: %{
          total: non_neg_integer(),
          remote: non_neg_integer(),
          removable: non_neg_integer() | nil,
          table_size: String.t()
        }
  def usage(cutoff \\ nil) do
    %{rows: [[size]]} =
      Repo.query!("SELECT pg_size_pretty(pg_total_relation_size('statuses'))")

    %{
      total: Repo.aggregate(Status, :count),
      remote: Status |> where([s], s.local == false) |> Repo.aggregate(:count),
      # Only when asked. Working out what a prune would take is the recursive
      # walk over every post on the server, and running it to print nothing is
      # a minute somebody waits for no reason.
      removable: cutoff && count(cutoff),
      table_size: size
    }
  end

  ## The query itself

  # Anchors first, then everything above them.
  #
  # The recursive half unions two walks: up `in_reply_to_id` so a kept reply
  # keeps the thread it hangs from, and up `reblog_of_id` so a kept boost keeps
  # the post it boosts. `UNION` rather than `UNION ALL` is what makes it
  # terminate on a diamond, where two kept replies share an ancestor.
  #
  # Written out rather than composed from Ecto fragments because a recursive
  # CTE has to name itself, and the anchor is a union of a dozen `EXISTS`
  # clauses that read as a list here and as noise in query syntax.
  @kept_cte """
  SELECT s.id, s.in_reply_to_id, s.reblog_of_id
    FROM statuses s
   WHERE s.local = TRUE
      OR EXISTS (SELECT 1 FROM favourites f WHERE f.status_id = s.id)
      OR EXISTS (SELECT 1 FROM bookmarks b WHERE b.status_id = s.id)
      OR EXISTS (SELECT 1 FROM status_pins p WHERE p.status_id = s.id)
      OR EXISTS (SELECT 1 FROM notifications n WHERE n.status_id = s.id)
      OR EXISTS (SELECT 1 FROM filter_statuses fs WHERE fs.status_id = s.id)
      OR EXISTS (SELECT 1 FROM quotes q WHERE q.quoted_status_id = s.id)
      OR EXISTS (
           SELECT 1 FROM feed_entries fe
            WHERE fe.status_id = s.id
              AND (fe.feed_type = 'list'
                   OR EXISTS (SELECT 1 FROM accounts a
                               WHERE a.id = fe.feed_id AND a.domain IS NULL)))
      OR EXISTS (SELECT 1 FROM reports r WHERE s.id = ANY(r.status_ids))
      OR EXISTS (
           SELECT 1 FROM polls po
             JOIN poll_votes pv ON pv.poll_id = po.id
            WHERE po.status_id = s.id)
      OR EXISTS (
           SELECT 1 FROM mentions m
             JOIN accounts a ON a.id = m.account_id
            WHERE m.status_id = s.id AND a.domain IS NULL)
      OR EXISTS (
           SELECT 1 FROM account_conversations ac
            WHERE ac.conversation_id = s.conversation_id)
  UNION
  SELECT p.id, p.in_reply_to_id, p.reblog_of_id
    FROM statuses p
    JOIN kept k ON p.id = k.in_reply_to_id OR p.id = k.reblog_of_id
  """

  # Never by age, whoever sent them and whatever anybody did with them. A
  # direct or limited post was addressed to particular people rather than
  # published, the volume is a rounding error next to a public timeline, and
  # the cost of removing one by mistake is somebody's correspondence.
  @never_by_age [:direct, :limited]

  # The rows that survive a prune belong to the remote author's own home feed,
  # which nobody here can open. Left behind they would outlive every post they
  # name and never be read.
  defp drop_feed_rows(cutoff) do
    ids = cutoff |> removable() |> select([s], s.id)

    Repo.delete_all(from(e in "feed_entries", where: e.status_id in subquery(ids)),
      timeout: :infinity
    )

    Repo.delete_all(from(e in "feed_entries", where: e.hidden_by_status_id in subquery(ids)),
      timeout: :infinity
    )
  end

  defp removable(cutoff) do
    from(s in Status,
      where: s.local == false,
      where: s.inserted_at < ^cutoff,
      where: s.visibility not in ^@never_by_age,
      where: fragment("NOT EXISTS (SELECT 1 FROM kept k WHERE k.id = ?)", s.id)
    )
    |> recursive_ctes(true)
    |> with_cte("kept", as: fragment(@kept_cte))
  end
end
