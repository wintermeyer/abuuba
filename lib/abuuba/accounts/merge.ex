defmodule Abuuba.Accounts.Merge do
  @moduledoc """
  Two rows that are one person, made into one row.

  ## Only accounts from elsewhere

  A duplicate is a bookkeeping accident, not a life event. Somebody on another
  server renames themselves or moves domain, this server hears about it as a
  new actor, and now two rows hold the same person's posts, follows and blocks.
  Nobody chose that and nobody can fix it from their end.

  Merging two *local* accounts is a different thing wearing the same word.
  Their posts have addresses other servers have stored, their usernames are
  promises this server made, and "which of these two is you" is a question with
  an owner. That is what moving an account is for, and it asks the person
  rather than an admin at a shell. This refuses local accounts outright.

  ## The key is what says they are the same

  Two actors with the same signing key are the same actor: nobody else can sign
  as them. That is the check, and `--force` exists because a server that
  rotated its keys between the two fetches leaves a duplicate the check cannot
  recognise. Forcing without that reason is asserting that two strangers are
  one person, and every post one of them wrote becomes the other's.

  ## What moves

  Everything that names the duplicate, found by asking the database which
  columns point at `accounts` rather than by keeping a list here. A list would
  be right on the day it was written and quietly wrong the first time a table
  was added — and the failure is silent, because a missed reference is a row
  pointing at an account that no longer exists.

  Two shapes have to be handled before the move rather than after:

    * A row that would collide. Somebody may have followed, blocked or muted
      *both* rows, which is precisely what having two of them allowed. The
      duplicate's row is dropped and the surviving one kept, because they say
      the same thing.

    * A row that would point at itself. The duplicate may have followed the
      account it is about to become, and an account following itself is a state
      nothing else here can produce or undo.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Repo

  @doc """
  Merges `duplicate` into `keeper` and deletes the duplicate.

  Everything happens in one transaction: half a merge leaves rows pointing at
  an account that is gone, and there is no way back from that but a backup.
  """
  @spec merge(Account.t(), Account.t()) ::
          {:ok, non_neg_integer()} | {:error, :local_account | :same_account}
  def merge(%Account{} = duplicate, %Account{} = keeper) do
    with :ok <- mergeable(duplicate, keeper) do
      Repo.transaction(fn ->
        moved = move_all(duplicate, keeper)
        Repo.delete!(duplicate)

        moved
      end)
    end
  end

  @doc """
  How many rows a merge would move, without moving any.

  Runs the merge and rolls it back, rather than counting the rows that name the
  duplicate. Those two numbers are not the same — a row that collides with one
  the survivor already has is dropped rather than moved — and a dry run whose
  number differs from the real one is a number somebody trusted.
  """
  @spec would_move(Account.t(), Account.t()) ::
          {:ok, non_neg_integer()} | {:error, :local_account | :same_account}
  def would_move(%Account{} = duplicate, %Account{} = keeper) do
    with :ok <- mergeable(duplicate, keeper) do
      Repo.transaction(fn -> Repo.rollback({:would_move, move_all(duplicate, keeper)}) end)
      |> case do
        {:error, {:would_move, count}} -> {:ok, count}
      end
    end
  end

  @doc """
  Whether two accounts carry the same signing key.

  The question "are these the same person", answered by the only thing that can
  answer it: nobody else can sign as them.
  """
  @spec same_key?(Account.t(), Account.t()) :: boolean()
  def same_key?(%Account{} = one, %Account{} = other) do
    case {public_key(one), public_key(other)} do
      {nil, _} -> false
      {_, nil} -> false
      {key, key} -> true
      _different -> false
    end
  end

  @doc """
  Remote accounts that sign with the same key, grouped, oldest id first.

  Report only. A shared key is what `same_key?/2` calls the same person and is
  the check `merge/2` refuses to proceed without, so this finds exactly the
  pairs that merge would accept — but which of the two survives is a judgement
  about which handle people know, and that is not a query's to make.

  ## Why it groups on the latest key rather than on `keypairs`

  `same_key?/2` compares each account's newest live key. The unique index on
  `keypairs` only holds for rows with a private half, so a *remote* account may
  legitimately have several live public keys. Grouping on the table directly
  would report such an account as a duplicate of itself, and would miss a pair
  whose only match is on the keys they use now. A detector that disagrees with
  the check the merge gates on sends an admin to do something the merge then
  refuses.
  """
  @spec duplicates() :: [[Account.t()]]
  def duplicates do
    case Repo.all(shared_keys()) do
      [] -> []
      keys -> groups_for(keys)
    end
  end

  # `DISTINCT ON (account_id) ... ORDER BY account_id, id DESC` is the newest
  # live key per account, which is what `public_key/1` reads one row at a time.
  defp latest_keys do
    from(k in "keypairs",
      where: is_nil(k.revoked_at),
      distinct: k.account_id,
      order_by: [asc: k.account_id, desc: k.id],
      select: %{account_id: k.account_id, public_key: k.public_key}
    )
  end

  defp shared_keys do
    from(l in subquery(latest_keys()),
      join: a in Account,
      on: a.id == l.account_id,
      where: not is_nil(a.domain),
      group_by: l.public_key,
      having: count(l.account_id) > 1,
      select: l.public_key
    )
  end

  # Only the accounts in a group are loaded, so a server with a million remote
  # actors and no duplicates reads no accounts at all.
  defp groups_for(keys) do
    from(l in subquery(latest_keys()),
      join: a in Account,
      on: a.id == l.account_id,
      where: not is_nil(a.domain) and l.public_key in ^keys,
      order_by: [asc: l.public_key, asc: a.id],
      select: {l.public_key, a}
    )
    |> Repo.all()
    |> Enum.chunk_by(fn {key, _account} -> key end)
    |> Enum.map(fn chunk -> Enum.map(chunk, fn {_key, account} -> account end) end)
  end

  ## Plumbing

  defp move_all(duplicate, keeper) do
    references()
    |> Enum.map(&move(&1, duplicate.id, keeper.id))
    |> Enum.sum()
  end

  defp mergeable(%Account{id: id}, %Account{id: id}), do: {:error, :same_account}

  defp mergeable(duplicate, keeper) do
    if Account.local?(duplicate) or Account.local?(keeper) do
      {:error, :local_account}
    else
      :ok
    end
  end

  defp public_key(%Account{id: id}) do
    from(k in "keypairs",
      where: k.account_id == ^id and is_nil(k.revoked_at),
      order_by: [desc: k.id],
      limit: 1,
      select: k.public_key
    )
    |> Repo.one()
  end

  # Every single-column foreign key pointing at `accounts`, with the unique
  # indexes that column takes part in. Asked of the database rather than
  # written down, so a table added tomorrow is covered without anybody
  # remembering this module exists.
  defp references do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.conrelid::regclass::text,
             a.attname,
             -- One string per unique index, columns comma-joined. An array of
             -- arrays cannot be built here: `array_agg` refuses to stack rows
             -- of different lengths, and two unique indexes rarely have the
             -- same number of columns.
             coalesce(
               (SELECT array_agg(cols.names)
                  FROM (
                    SELECT string_agg(ic.attname::text, ',' ORDER BY ic.attname) AS names
                      FROM pg_index i
                      JOIN pg_attribute ic
                        ON ic.attrelid = i.indrelid AND ic.attnum = ANY(i.indkey)
                     WHERE i.indrelid = c.conrelid
                       AND i.indisunique
                       AND a.attnum = ANY(i.indkey)
                     GROUP BY i.indexrelid
                  ) AS cols),
               '{}')
        FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
       WHERE c.contype = 'f'
         AND c.confrelid = 'accounts'::regclass
         AND array_length(c.conkey, 1) = 1
      """)

    for [table, column, uniques] <- rows, table != "accounts" or column != "id" do
      {table, column, Enum.map(uniques || [], &String.split(&1, ","))}
    end
  end

  defp move({table, column, uniques}, from_id, to_id) do
    drop_self_references(table, column, from_id, to_id)
    Enum.each(uniques, &drop_collisions(table, column, &1, from_id, to_id))

    {moved, _returned} =
      Repo.query!(
        "UPDATE #{quoted(table)} SET #{quoted(column)} = $1 WHERE #{quoted(column)} = $2",
        [to_id, from_id]
      )
      |> then(&{&1.num_rows, nil})

    moved
  end

  # A row naming the duplicate in one column and the survivor in another would
  # name the survivor twice after the move: an account following, blocking or
  # muting itself.
  defp drop_self_references(table, column, from_id, to_id) do
    for other <- other_account_columns(table, column) do
      Repo.query!(
        "DELETE FROM #{quoted(table)} WHERE #{quoted(column)} = $1 AND #{quoted(other)} = $2",
        [from_id, to_id]
      )
    end
  end

  # The duplicate's row where the survivor already has one saying the same
  # thing. Dropped rather than merged: two follows of the same person are one
  # follow, and there is nothing in either row the other does not have.
  defp drop_collisions(table, column, unique_columns, from_id, to_id) do
    # An index on the account column alone — a counters row, a preference row —
    # means the survivor's own row is the one that stays and the duplicate's
    # goes. Nothing is added up: a count is derived from rows that have just
    # moved, so summing two stale numbers would be less true than keeping one.
    matches =
      unique_columns
      |> Enum.reject(&(&1 == column))
      |> case do
        [] -> "TRUE"
        rest -> Enum.map_join(rest, " AND ", &"b.#{quoted(&1)} = a.#{quoted(&1)}")
      end

    Repo.query!(
      """
      DELETE FROM #{quoted(table)} a
       WHERE a.#{quoted(column)} = $1
         AND EXISTS (
           SELECT 1 FROM #{quoted(table)} b
            WHERE b.#{quoted(column)} = $2 AND #{matches}
         )
      """,
      [from_id, to_id]
    )
  end

  defp other_account_columns(table, column) do
    references()
    |> Enum.filter(fn {other_table, other_column, _uniques} ->
      other_table == table and other_column != column
    end)
    |> Enum.map(fn {_table, other_column, _uniques} -> other_column end)
  end

  # Identifiers come from the database's own catalogue rather than from
  # anything anybody typed, so this is belt and braces — but a quoted
  # identifier is what makes that true rather than nearly true.
  defp quoted(identifier), do: ~s("#{String.replace(identifier, ~s("), ~s(""))}")
end
