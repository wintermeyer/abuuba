defmodule Abuuba.Stats do
  @moduledoc """
  The counter caches on accounts and statuses.

  Counters are never read, modified and written back. Every change goes out as
  one statement whose right-hand side is an expression evaluated by Postgres:

      INSERT INTO status_stats (status_id, favourites_count, ...)
      VALUES ($1, 1, ...)
      ON CONFLICT (status_id)
      DO UPDATE SET favourites_count = status_stats.favourites_count + 1

  The reason is the obvious one and it bites constantly. Two people favouriting
  a post at the same moment both read 5, both write 6, and one favourite has
  vanished with nothing to show that it did. The statement above has no read to
  be stale, and it also creates the row on first use, so nothing has to
  remember to insert a stats row when an account or a status is created.

  Counters here are a cache, not the truth. The rows in `favourites`, `follows`
  and `statuses` are. If the two ever disagree, `drift/0` says by how much and
  `recount/0` puts it right from those rows; `mix abuuba.stats` is the same two
  from a shell.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Repo
  alias Abuuba.Stats.AccountStat
  alias Abuuba.Stats.StatusStat
  alias Abuuba.Statuses.Status

  @account_counters ~w(statuses_count following_count followers_count)a
  @status_counters ~w(replies_count reblogs_count favourites_count quotes_count)a

  @doc """
  Adjusts an account's counters.

      Stats.bump_account(account, followers_count: 1)
      Stats.bump_account(account, following_count: -1)

  Also accepts `last_status_at`, which is set rather than added to.
  """
  @spec bump_account(Account.t() | integer(), keyword()) :: :ok
  def bump_account(%Account{id: id}, changes), do: bump_account(id, changes)

  def bump_account(account_id, changes) do
    validate_keys!(changes, @account_counters ++ [:last_status_at])
    {counters, sets} = Keyword.split(changes, @account_counters)

    bump(AccountStat, :account_id, account_id, counters, sets)
  end

  @doc """
  Adjusts a status's counters.

      Stats.bump_status(status, favourites_count: 1)
  """
  @spec bump_status(Status.t() | integer(), keyword()) :: :ok
  def bump_status(%Status{id: id}, changes), do: bump_status(id, changes)

  def bump_status(status_id, changes) do
    validate_keys!(changes, @status_counters)
    {counters, sets} = Keyword.split(changes, @status_counters)

    bump(StatusStat, :status_id, status_id, counters, sets)
  end

  @doc """
  Takes everything a departing account contributed back out of the counters.

  Called before the account's rows are hard-deleted: the cascades silently
  drop its favourites, boosts, replies and follows, and every counter those
  rows moved would otherwise stay inflated forever, with the truth to recount
  from gone. Grouped statements rather than a walk — an account with a
  hundred thousand favourites is four statements, not a hundred thousand.
  Floored at zero so drift from before the counters were maintained cannot
  trip the CHECK constraints.
  """
  @spec retract_account(Account.t() | integer()) :: :ok
  def retract_account(%Account{id: id}), do: retract_account(id)

  def retract_account(account_id) do
    Repo.query!(
      """
      UPDATE status_stats ss
      SET favourites_count = GREATEST(ss.favourites_count - x.marks, 0), updated_at = now()
      FROM (
        SELECT status_id, count(*) AS marks
        FROM favourites WHERE account_id = $1 GROUP BY status_id
      ) x
      WHERE ss.status_id = x.status_id
      """,
      [account_id]
    )

    # Only what was counted on the way in comes back out: quiet replies and
    # direct messages never moved a counter (see `Abuuba.Statuses`).
    Repo.query!(
      """
      UPDATE status_stats ss
      SET replies_count = GREATEST(ss.replies_count - x.replies, 0), updated_at = now()
      FROM (
        SELECT in_reply_to_id AS status_id, count(*) AS replies
        FROM statuses
        WHERE account_id = $1 AND deleted_at IS NULL
          AND in_reply_to_id IS NOT NULL AND visibility IN ('public', 'unlisted')
        GROUP BY in_reply_to_id
      ) x
      WHERE ss.status_id = x.status_id
      """,
      [account_id]
    )

    Repo.query!(
      """
      UPDATE status_stats ss
      SET reblogs_count = GREATEST(ss.reblogs_count - x.boosts, 0), updated_at = now()
      FROM (
        SELECT reblog_of_id AS status_id, count(*) AS boosts
        FROM statuses
        WHERE account_id = $1 AND deleted_at IS NULL
          AND reblog_of_id IS NOT NULL AND visibility <> 'direct'
        GROUP BY reblog_of_id
      ) x
      WHERE ss.status_id = x.status_id
      """,
      [account_id]
    )

    Repo.query!(
      """
      UPDATE account_stats
      SET followers_count = GREATEST(followers_count - 1, 0), updated_at = now()
      WHERE account_id IN (SELECT target_account_id FROM follows WHERE account_id = $1)
      """,
      [account_id]
    )

    Repo.query!(
      """
      UPDATE account_stats
      SET following_count = GREATEST(following_count - 1, 0), updated_at = now()
      WHERE account_id IN (SELECT account_id FROM follows WHERE target_account_id = $1)
      """,
      [account_id]
    )

    :ok
  end

  @doc """
  An account's counters, zeroed if nothing has happened to it yet.
  """
  @spec account_stats(Account.t() | integer()) :: map()
  def account_stats(%Account{id: id}), do: account_stats(id)

  def account_stats(account_id) do
    read(AccountStat, :account_id, account_id, @account_counters ++ [:last_status_at])
  end

  @doc """
  A status's counters, zeroed if nothing has happened to it yet.
  """
  @spec status_stats(Status.t() | integer()) :: map()
  def status_stats(%Status{id: id}), do: status_stats(id)

  def status_stats(status_id) do
    read(StatusStat, :status_id, status_id, @status_counters)
  end

  defp bump(_schema, _key_field, _key, [], []), do: :ok

  defp bump(schema, key_field, key, counters, sets) do
    now = DateTime.utc_now()

    # Floored at zero for the insert, not for the update. Postgres validates
    # the proposed row against the table's CHECK constraints before it notices
    # the conflict, so a decrement arriving before the row exists would be
    # rejected for proposing a negative count even though the conflict branch
    # would never have written one. Starting a fresh row at zero is also the
    # right answer: there was nothing there to take one away from.
    floored = Enum.map(counters, fn {counter, by} -> {counter, max(by, 0)} end)

    row =
      floored
      |> Keyword.merge(sets)
      |> Keyword.merge([{key_field, key}, {:inserted_at, now}, {:updated_at, now}])

    Repo.insert_all(schema, [row],
      conflict_target: [key_field],
      # `inc` is what makes this safe: Ecto renders it as
      # `SET col = table.col + $n`, so the new value is computed inside the
      # statement rather than carried in from a value we read a moment ago.
      on_conflict: [inc: counters, set: sets ++ [updated_at: now]]
    )

    :ok
  end

  defp read(schema, key_field, key, columns) do
    query =
      from(t in schema,
        where: field(t, ^key_field) == ^key,
        select: map(t, ^columns)
      )

    Repo.one(query) || Map.new(columns, &{&1, zero_for(&1)})
  end

  defp zero_for(:last_status_at), do: nil
  defp zero_for(_counter), do: 0

  # Checked against what the caller passed, not against what survived the
  # split: a misspelled counter is not a counter, so it would otherwise fall
  # through to the plain-set half and reach Postgres as a column that does not
  # exist, reported from somewhere far from the typo.
  defp validate_keys!(changes, allowed) do
    case Keyword.keys(changes) -- allowed do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown counters: #{inspect(unknown)}"
    end
  end

  ## Recounting

  @doc """
  How many counter rows disagree with the rows they cache.

  Answers without writing, so an operator can see whether there is anything
  wrong before deciding to touch a production table.
  """
  @spec drift() :: %{accounts: non_neg_integer(), statuses: non_neg_integer()}
  def drift do
    %{
      accounts: Repo.query!(account_sql(:count), []).rows |> hd() |> hd(),
      statuses: Repo.query!(status_sql(:count), []).rows |> hd() |> hd()
    }
  end

  @doc """
  Recomputes the counter caches from the rows that are the truth, and answers
  how many rows had to change.

  ## Why this is set-based and not a walk

  A server with a million accounts is two statements, not two million. The
  same reason `retract_account/1` is written the way it is.

  ## What it deliberately does not touch

  `last_status_at`. It is a timestamp rather than a count, and an imported post
  sets the counters without setting it, on purpose: an archive is old news and
  stamping it would put a decade-old post forward as the latest thing somebody
  said. Recomputing it from `max(inserted_at)` would undo that on every server
  that has ever run an import.

  ## Run it when the server is quiet, or run it twice

  Each statement reads the source rows and writes the counter as one statement,
  but the two are not one transaction with the writes going on around them. A
  favourite that lands after the count is read and before the counter is
  written is counted by its own increment and then overwritten, so a recount
  under load can leave one behind. Running it again finds it. That is worth
  saying plainly, because a repair tool that quietly creates the fault it
  repairs is the worst kind.

  ## Why the predicates are repeated here

  They have to match `Abuuba.Statuses.count_status/3` exactly. A recount that
  counts something the increments never counted does not repair drift, it
  writes drift to every row at once, and it looks like a fix while doing it.
  Direct posts move no counter; a reply only counts when it is public or
  unlisted; deleted rows count for nothing; a quote counts once accepted.
  """
  @spec recount() :: %{accounts: non_neg_integer(), statuses: non_neg_integer()}
  def recount do
    %{
      accounts: Repo.query!(account_sql(:fix), []).num_rows,
      statuses: Repo.query!(status_sql(:fix), []).num_rows
    }
  end

  # The expected numbers for every account that has a counter row or anything
  # to count. Restricted so a server does not gain a stats row for every remote
  # account it has merely heard of.
  defp account_expected do
    """
    SELECT a.id AS account_id,
           (SELECT count(*) FROM statuses s
              WHERE s.account_id = a.id
                AND s.deleted_at IS NULL
                AND s.visibility <> 'direct') AS statuses_count,
           (SELECT count(*) FROM follows f WHERE f.account_id = a.id) AS following_count,
           (SELECT count(*) FROM follows f WHERE f.target_account_id = a.id) AS followers_count
      FROM accounts a
     WHERE EXISTS (SELECT 1 FROM account_stats st WHERE st.account_id = a.id)
        OR EXISTS (SELECT 1 FROM statuses s WHERE s.account_id = a.id
                     AND s.deleted_at IS NULL AND s.visibility <> 'direct')
        OR EXISTS (SELECT 1 FROM follows f WHERE f.account_id = a.id)
        OR EXISTS (SELECT 1 FROM follows f WHERE f.target_account_id = a.id)
    """
  end

  # The `WHERE EXISTS` guards repeat the predicates from the counts above, and
  # have to. A guard that is looser than its count pulls in a status with
  # nothing to count, writes it a row of zeros, and makes `drift/0` report work
  # to do on a database where nothing is wrong. A private reply to a post
  # nobody has otherwise touched is exactly that case.
  defp status_expected do
    """
    SELECT s.id AS status_id,
           (SELECT count(*) FROM statuses r
              WHERE r.in_reply_to_id = s.id
                AND r.deleted_at IS NULL
                AND r.visibility IN ('public', 'unlisted')) AS replies_count,
           (SELECT count(*) FROM statuses b
              WHERE b.reblog_of_id = s.id
                AND b.deleted_at IS NULL
                AND b.visibility <> 'direct') AS reblogs_count,
           (SELECT count(*) FROM favourites v WHERE v.status_id = s.id) AS favourites_count,
           (SELECT count(*) FROM quotes q
              WHERE q.quoted_status_id = s.id AND q.state = 'accepted') AS quotes_count
      FROM statuses s
     WHERE EXISTS (SELECT 1 FROM status_stats st WHERE st.status_id = s.id)
        OR EXISTS (SELECT 1 FROM statuses r WHERE r.in_reply_to_id = s.id
                     AND r.deleted_at IS NULL
                     AND r.visibility IN ('public', 'unlisted'))
        OR EXISTS (SELECT 1 FROM statuses b WHERE b.reblog_of_id = s.id
                     AND b.deleted_at IS NULL AND b.visibility <> 'direct')
        OR EXISTS (SELECT 1 FROM favourites v WHERE v.status_id = s.id)
        OR EXISTS (SELECT 1 FROM quotes q
                     WHERE q.quoted_status_id = s.id AND q.state = 'accepted')
    """
  end

  defp account_sql(:count) do
    """
    SELECT count(*) FROM (#{account_expected()}) e
    LEFT JOIN account_stats st ON st.account_id = e.account_id
    WHERE (COALESCE(st.statuses_count, -1), COALESCE(st.following_count, -1),
           COALESCE(st.followers_count, -1))
          IS DISTINCT FROM (e.statuses_count, e.following_count, e.followers_count)
    """
  end

  defp account_sql(:fix) do
    """
    INSERT INTO account_stats
      (account_id, statuses_count, following_count, followers_count, inserted_at, updated_at)
    SELECT e.account_id, e.statuses_count, e.following_count, e.followers_count, now(), now()
      FROM (#{account_expected()}) e
    ON CONFLICT (account_id) DO UPDATE
       SET statuses_count = EXCLUDED.statuses_count,
           following_count = EXCLUDED.following_count,
           followers_count = EXCLUDED.followers_count,
           updated_at = now()
     WHERE (account_stats.statuses_count, account_stats.following_count,
            account_stats.followers_count)
           IS DISTINCT FROM (EXCLUDED.statuses_count, EXCLUDED.following_count,
                             EXCLUDED.followers_count)
    """
  end

  defp status_sql(:count) do
    """
    SELECT count(*) FROM (#{status_expected()}) e
    LEFT JOIN status_stats st ON st.status_id = e.status_id
    WHERE (COALESCE(st.replies_count, -1), COALESCE(st.reblogs_count, -1),
           COALESCE(st.favourites_count, -1), COALESCE(st.quotes_count, -1))
          IS DISTINCT FROM (e.replies_count, e.reblogs_count, e.favourites_count,
                            e.quotes_count)
    """
  end

  defp status_sql(:fix) do
    """
    INSERT INTO status_stats
      (status_id, replies_count, reblogs_count, favourites_count, quotes_count,
       inserted_at, updated_at)
    SELECT e.status_id, e.replies_count, e.reblogs_count, e.favourites_count,
           e.quotes_count, now(), now()
      FROM (#{status_expected()}) e
    ON CONFLICT (status_id) DO UPDATE
       SET replies_count = EXCLUDED.replies_count,
           reblogs_count = EXCLUDED.reblogs_count,
           favourites_count = EXCLUDED.favourites_count,
           quotes_count = EXCLUDED.quotes_count,
           updated_at = now()
     WHERE (status_stats.replies_count, status_stats.reblogs_count,
            status_stats.favourites_count, status_stats.quotes_count)
           IS DISTINCT FROM (EXCLUDED.replies_count, EXCLUDED.reblogs_count,
                             EXCLUDED.favourites_count, EXCLUDED.quotes_count)
    """
  end
end
