defmodule Abuuba.Timelines.Feed do
  @moduledoc """
  Reading and writing the `feed_entries` table.

  ## The bet

  A home timeline is "everything by everybody I follow, minus what I filtered
  out". Asking that at read time means joining the follow graph on every
  scroll, for every reader, forever. Writing the answer once when a post is
  made turns every read into an index scan over one account's rows, and the
  index is the primary key.

  ## Three columns

  The status id is a snowflake, so it is the timestamp, the sort key and the
  pagination cursor at once. A `created_at` column would store the same
  information twice in the table that grows fastest.

  ## The cap is trimmed, not enforced

  A feed keeps roughly its newest few hundred entries. Enforcing that on every
  insert turns one write into a write and a delete on the hottest path there
  is, so a sweeper does it instead and a feed is allowed to run over in
  between. Nobody scrolls past the cap in the seconds it takes.
  """

  import Ecto.Query

  alias Abuuba.Repo

  # Deep enough that nobody reaches the end of it in normal reading, shallow
  # enough that one account's feed is a handful of pages of rows.
  @limit 800

  @types ~w(home list)

  @doc """
  How many entries a feed keeps.
  """
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc """
  Puts one post in one feed. Doing it twice is doing it once.
  """
  @spec insert(String.t(), integer(), integer()) :: :ok
  def insert(type, feed_id, status_id) when type in @types do
    insert_many([%{feed_type: type, feed_id: feed_id, status_id: status_id}])
  end

  @doc """
  Puts many rows in, in one statement.

  This is the whole point of the chunked fan-out: five hundred followers is one
  insert rather than five hundred.
  """
  @spec insert_many([map()]) :: :ok
  def insert_many([]), do: :ok

  def insert_many(rows) do
    # Sorted into primary-key order before the insert. `ON CONFLICT DO NOTHING`
    # takes a lock per row as it goes, so two fan-outs writing overlapping rows
    # in different orders can each hold what the other is waiting for. Every
    # writer taking them in the same order is what makes that impossible, and
    # sorting a few hundred tuples costs nothing next to the round trip.
    Repo.insert_all(
      "feed_entries",
      Enum.sort_by(rows, &{&1.feed_type, &1.feed_id, &1.status_id}),
      on_conflict: :nothing
    )

    :ok
  end

  @doc """
  The status ids in a feed, newest first, seeking by cursor.

  Ids rather than statuses: the caller loads them with whatever it needs
  preloaded, and this table knows nothing about what a status is.
  """
  @spec status_ids(String.t(), integer(), map()) :: [integer()]
  def status_ids(type, feed_id, page \\ %{}) do
    # `:asc` asks for the page immediately above a cursor, so the limit has to
    # bite at the oldest end of it. Which way to read is `Abuuba.Pagination`'s
    # one rule — a private copy of it here is what produced the bug it
    # replaced, when that copy matched `%{min_id: _id}` on the key rather
    # than the value and every feed read came back oldest-first.
    base(type, feed_id)
    |> before_cursor(Map.get(page, :max_id))
    |> after_cursor(Map.get(page, :min_id) || Map.get(page, :since_id))
    |> order_by([e], [{^Abuuba.Pagination.direction(page), e.status_id}])
    |> limit(^Map.get(page, :limit, 20))
    |> select([e], e.status_id)
    |> Repo.all()
  end

  @doc """
  How many entries a feed holds.
  """
  @spec count(String.t(), integer()) :: non_neg_integer()
  def count(type, feed_id), do: type |> all_entries(feed_id) |> Repo.aggregate(:count)

  @doc """
  The newest id in a feed, or `nil`.
  """
  @spec newest(String.t(), integer()) :: integer() | nil
  def newest(type, feed_id) do
    type |> base(feed_id) |> select([e], max(e.status_id)) |> Repo.one()
  end

  @doc """
  Drops everything past the cap, keeping the newest.
  """
  @spec trim(String.t(), integer()) :: :ok
  def trim(type, feed_id) do
    # The oldest id worth keeping, then a delete bounded by it. Written as
    # `NOT IN (subquery)` instead, Postgres has no index to drive the negation
    # and scans the whole table, taking locks on rows belonging to feeds this
    # call has nothing to do with; two of those against concurrent inserts is a
    # deadlock. A range on the primary key touches only this feed's rows.
    case oldest_kept(type, feed_id) do
      nil ->
        :ok

      cutoff ->
        all_entries(type, feed_id)
        |> where([e], e.status_id < ^cutoff)
        |> Repo.delete_all()

        :ok
    end
  end

  defp oldest_kept(type, feed_id) do
    all_entries(type, feed_id)
    |> order_by([e], desc: e.status_id)
    |> offset(^(@limit - 1))
    |> limit(1)
    |> select([e], e.status_id)
    |> Repo.one()
  end

  @doc """
  Takes one post out of every feed it reached.

  What a deletion needs, and the one query here that is not by feed, which is
  why the status id has an index of its own.
  """
  @spec remove_status(integer()) :: :ok
  def remove_status(status_id) do
    # Whoever was standing behind it comes forward first, in every feed that
    # was showing it, in one statement: a viral post sits in thousands of
    # feeds, and promoting per feed was three statements each. Same rule as
    # `remove_chunk/3`, grouped by feed instead of by departing entry.
    Repo.query!(
      """
      WITH leaders AS (
        SELECT feed_type, feed_id, min(status_id) AS leader
        FROM feed_entries
        WHERE hidden_by_status_id = $1
        GROUP BY feed_type, feed_id
      )
      UPDATE feed_entries e
      SET hidden_by_status_id = CASE WHEN e.status_id = l.leader THEN NULL ELSE l.leader END
      FROM leaders l
      WHERE e.feed_type = l.feed_type AND e.feed_id = l.feed_id
        AND e.hidden_by_status_id = $1
      """,
      [status_id]
    )

    from(e in "feed_entries", where: e.status_id == ^status_id) |> Repo.delete_all()

    :ok
  end

  @doc """
  Takes everything one account wrote out of one feed.

  What unfollowing and blocking need. Their posts stop arriving from now on
  either way; this is what clears the ones already there, and without it
  somebody who just blocked a person keeps reading them.
  """
  @spec remove_author(String.t(), integer(), integer()) :: :ok
  def remove_author(type, feed_id, author_id) do
    # Read the ids, then delete them by id, in order. One statement with a
    # subquery makes Postgres take locks on `statuses` rows in whatever order
    # the plan produces, and two of these running against each other while
    # posts are being written is a deadlock. Sorted explicit ids give every
    # caller the same lock order, which is the standard cure.
    doomed =
      all_entries(type, feed_id)
      |> join(:inner, [e], s in "statuses", on: s.id == e.status_id)
      |> where([_e, s], s.account_id == ^author_id)
      |> select([e], e.status_id)
      |> Repo.all()
      |> Enum.sort()

    remove(type, feed_id, doomed)
  end

  @doc """
  Takes named posts out of one feed.
  """
  @spec remove(String.t(), integer(), [integer()]) :: :ok
  def remove(_type, _feed_id, []), do: :ok

  def remove(type, feed_id, status_ids) do
    # Chunked so a purge naming an account's whole history stays a handful of
    # bounded statements rather than one with a hundred-thousand-element
    # parameter.
    status_ids
    |> Enum.chunk_every(1000)
    |> Enum.each(&remove_chunk(type, feed_id, &1))

    :ok
  end

  defp remove_chunk(type, feed_id, status_ids) do
    # Whoever was standing behind each departing entry comes forward, in one
    # statement for the whole set rather than three per id. Per surviving
    # group the oldest member is made visible and the rest stand behind it;
    # members that are departing too are simply deleted below. The oldest is
    # chosen because it is the one that would have been shown had the
    # departing entry never existed.
    Repo.query!(
      """
      WITH leaders AS (
        SELECT hidden_by_status_id AS departing, min(status_id) AS leader
        FROM feed_entries
        WHERE feed_type = $1 AND feed_id = $2
          AND hidden_by_status_id = ANY($3)
          AND NOT (status_id = ANY($3))
        GROUP BY hidden_by_status_id
      )
      UPDATE feed_entries e
      SET hidden_by_status_id = CASE WHEN e.status_id = l.leader THEN NULL ELSE l.leader END
      FROM leaders l
      WHERE e.feed_type = $1 AND e.feed_id = $2
        AND e.hidden_by_status_id = l.departing
        AND NOT (e.status_id = ANY($3))
      """,
      [type, feed_id, status_ids]
    )

    all_entries(type, feed_id)
    |> where([e], e.status_id in ^status_ids)
    |> Repo.delete_all()
  end

  @doc """
  Empties a feed.
  """
  @spec clear(String.t(), integer()) :: :ok
  def clear(type, feed_id) do
    all_entries(type, feed_id) |> Repo.delete_all()

    :ok
  end

  @doc """
  Every feed holding more than the cap, for the sweeper.
  """
  @spec over_limit(pos_integer()) :: [{String.t(), integer()}]
  def over_limit(batch) do
    from(e in "feed_entries",
      group_by: [e.feed_type, e.feed_id],
      having: count(e.status_id) > @limit,
      select: {e.feed_type, e.feed_id},
      limit: ^batch
    )
    |> Repo.all()
  end

  @doc """
  Puts a post in behind another one, rather than on its own.

  What reblog aggregation stores: the entry is kept so it can be promoted when
  the one on show goes away, and left out of every read until then.
  """
  @spec insert_hidden(String.t(), integer(), integer(), integer()) :: :ok
  def insert_hidden(type, feed_id, status_id, behind_id) do
    insert_many([
      %{
        feed_type: type,
        feed_id: feed_id,
        status_id: status_id,
        hidden_by_status_id: behind_id
      }
    ])
  end

  @doc """
  Which entry in a feed is currently showing a given original, if any.

  A boost arriving looks for the original itself and for any boost of it: both
  put the same words on the page, so either is a reason to stand behind rather
  than beside.
  """
  @spec showing(String.t(), integer(), [integer()]) :: integer() | nil
  def showing(_type, _feed_id, []), do: nil

  def showing(type, feed_id, status_ids) do
    base(type, feed_id)
    |> where([e], e.status_id in ^status_ids and is_nil(e.hidden_by_status_id))
    |> order_by([e], desc: e.status_id)
    |> limit(1)
    |> select([e], e.status_id)
    |> Repo.one()
  end

  # Everything a read sees. Hidden entries are stored but never returned, which
  # is the whole of reblog aggregation as far as reading is concerned.
  @doc """
  Feeds belonging to accounts that no longer exist.

  `feed_entries` names an account by id and nothing enforces that the account
  is still there: a foreign key would put a lock on `accounts` in the path of
  every fan-out insert, which is the last place to spend one. So the check is a
  sweep instead.
  """
  @spec orphaned(pos_integer()) :: [{String.t(), integer()}]
  def orphaned(batch) do
    from(e in "feed_entries",
      left_join: a in "accounts",
      on: a.id == e.feed_id,
      where: e.feed_type == "home" and is_nil(a.id),
      select: {e.feed_type, e.feed_id},
      distinct: true,
      limit: ^batch
    )
    |> Repo.all()
  end

  @doc """
  Home feeds belonging to people who have not signed in for a long time.

  Rows nobody is reading in the largest table on the server. They are rebuilt
  if their owner comes back; see `Abuuba.Timelines.RegenerateWorker`.
  """
  @spec dormant(pos_integer(), pos_integer()) :: [integer()]
  def dormant(days, batch) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    from(e in "feed_entries",
      join: u in "users",
      on: u.account_id == e.feed_id,
      where: e.feed_type == "home",
      where: not is_nil(u.last_signed_in_at) and u.last_signed_in_at < ^cutoff,
      select: e.feed_id,
      distinct: true,
      limit: ^batch
    )
    |> Repo.all()
  end

  defp base(type, feed_id) do
    from(e in "feed_entries",
      where: e.feed_type == ^type and e.feed_id == ^feed_id and is_nil(e.hidden_by_status_id)
    )
  end

  # Including the hidden ones, for the operations that have to see everything:
  # counting what a feed holds, trimming it, emptying it.
  defp all_entries(type, feed_id) do
    from(e in "feed_entries", where: e.feed_type == ^type and e.feed_id == ^feed_id)
  end

  defp before_cursor(query, nil), do: query
  defp before_cursor(query, id), do: where(query, [e], e.status_id < ^id)

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, id), do: where(query, [e], e.status_id > ^id)
end
