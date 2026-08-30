defmodule Abuuba.Conversations do
  @moduledoc """
  Direct messages, as an inbox rather than a timeline.

  ## One row per person, not per conversation

  A conversation is shared; the state around it is not. Whether it has been
  read, whether it is muted and whether somebody has taken it out of their own
  inbox are each one person's answer, and storing them on the conversation
  would mean one person marking a thread read marks it read for everybody.

  ## Who is in it is part of which thread it is

  A private message to one person and a group message to three can belong to
  the same conversation. To the person reading them they are two threads, so
  the row is keyed by the participant set as well as the conversation. That is
  also what makes concurrent delivery safe: two messages arriving at once for
  the same people find the same row through the unique index rather than
  racing to create two.

  ## Removing is local

  Deleting a conversation takes it out of one inbox. A message somebody
  received does not give them a way to reach into the sender's. A later message
  brings the thread back, which is what somebody who deleted it and then got a
  reply expects.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Pagination
  alias Abuuba.Repo
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Mention
  alias Abuuba.Statuses.Status
  alias Abuuba.Streaming

  @doc """
  Files a direct message in the inbox of everybody it is between.

  Called for every direct status as it is written. Doing it twice is doing it
  once: the status id is added to a set rather than appended to a list.
  """
  @spec deliver(Status.t()) :: :ok
  def deliver(%Status{visibility: :direct, conversation_id: id} = status) when not is_nil(id) do
    everybody = participants(status)

    Enum.each(everybody, fn account_id ->
      upsert(account_id, status, Enum.sort(everybody -- [account_id]))

      # After the row, not instead of it. A `conversation` event is what a
      # client watching its messages column listens for, and it carries the
      # row -- so announcing before the write would announce a row that is not
      # there yet.
      announce(account_id)
    end)
  end

  def deliver(%Status{}), do: :ok

  @doc """
  Takes a deleted message out of every inbox that named it.

  The rows are not foreign-keyed to `statuses` -- a conversation outlives any
  one message in it -- so nothing cleans them up on its own, and a delete that
  said nothing left the inbox showing a line about a post nobody can open, with
  a readable one sitting behind it.

  A row whose last message was the one deleted falls back to the newest one
  left; a row with nothing left goes.
  """
  @spec forget(Status.t()) :: :ok
  def forget(%Status{visibility: :direct, id: id}) do
    rows =
      from(c in "account_conversations",
        where: fragment("? = ANY(?)", ^id, c.status_ids),
        select: %{id: c.id, account_id: c.account_id, status_ids: c.status_ids}
      )
      |> Repo.all()

    Enum.each(rows, &forget_from(&1, id))
  end

  def forget(%Status{}), do: :ok

  defp forget_from(row, status_id) do
    case Enum.reject(row.status_ids, &(&1 == status_id)) do
      [] ->
        from(c in "account_conversations", where: c.id == ^row.id) |> Repo.delete_all()

      left ->
        from(c in "account_conversations", where: c.id == ^row.id)
        |> Repo.update_all(
          set: [
            status_ids: left,
            last_status_id: Enum.max(left),
            updated_at: DateTime.utc_now()
          ]
        )
    end

    :ok
  end

  @doc """
  Somebody's inbox, newest activity first.
  """
  @spec list(Account.t() | integer(), map()) :: [map()]
  def list(account, page \\ %{})
  def list(%Account{id: id}, page), do: list(id, page)

  def list(account_id, page) do
    from(c in "account_conversations",
      where: c.account_id == ^account_id,
      select: %{
        id: c.id,
        account_id: c.account_id,
        conversation_id: c.conversation_id,
        participant_account_ids: c.participant_account_ids,
        status_ids: c.status_ids,
        last_status_id: c.last_status_id,
        unread: c.unread,
        muted: c.muted
      }
    )
    |> before_cursor(Map.get(page, :max_id))
    |> after_cursor(Map.get(page, :min_id) || Map.get(page, :since_id))
    |> order_by([c], [{^Pagination.direction(page), c.last_status_id}])
    |> limit(^Map.get(page, :limit, 20))
    |> Repo.all()
    |> Pagination.reading_order(page)
  end

  @doc """
  One of somebody's own rows, or `nil`.

  Scoped by account in the query rather than checked afterwards: one that
  cannot return a stranger's row cannot leak one.
  """
  @spec get(Account.t() | integer(), integer() | String.t()) :: map() | nil
  def get(%Account{id: id}, row_id), do: get(id, row_id)

  def get(account_id, row_id) do
    with {:ok, row_id} <- Snowflake.cast(row_id) do
      # The same shape `list/2` returns. A narrower one here would mean every
      # caller having to know which of the two it was holding.
      from(c in "account_conversations",
        where: c.account_id == ^account_id and c.id == ^row_id,
        select: %{
          id: c.id,
          account_id: c.account_id,
          conversation_id: c.conversation_id,
          participant_account_ids: c.participant_account_ids,
          status_ids: c.status_ids,
          last_status_id: c.last_status_id,
          unread: c.unread,
          muted: c.muted
        }
      )
      |> Repo.one()
    end
  end

  @doc """
  Marks a thread read.
  """
  @spec mark_read(Account.t() | integer(), integer() | String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def mark_read(account, row_id), do: set(account, row_id, unread: false)

  @doc """
  Marks it unread again, which is how somebody keeps something to come back to.
  """
  @spec mark_unread(Account.t() | integer(), integer() | String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def mark_unread(account, row_id), do: set(account, row_id, unread: true)

  @doc """
  Stops a thread being counted as waiting.

  It stays in the inbox and stays readable: muting is about not being told,
  not about hiding what was said.
  """
  @spec mute(Account.t() | integer(), integer() | String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def mute(account, row_id), do: set(account, row_id, muted: true, unread: false)

  @doc """
  Starts counting it again.
  """
  @spec unmute(Account.t() | integer(), integer() | String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def unmute(account, row_id), do: set(account, row_id, muted: false)

  @doc """
  Takes a thread out of one inbox.
  """
  @spec remove(Account.t() | integer(), integer() | String.t()) :: :ok
  def remove(%Account{id: id}, row_id), do: remove(id, row_id)

  def remove(account_id, row_id) do
    with {:ok, row_id} <- Snowflake.cast(row_id) do
      from(c in "account_conversations",
        where: c.account_id == ^account_id and c.id == ^row_id
      )
      |> Repo.delete_all()
    end

    :ok
  end

  @doc """
  How many threads are waiting, not counting muted ones.
  """
  @spec unread_count(Account.t() | integer()) :: non_neg_integer()
  def unread_count(%Account{id: id}), do: unread_count(id)

  def unread_count(account_id) do
    from(c in "account_conversations",
      where: c.account_id == ^account_id and c.unread and not c.muted
    )
    |> Repo.aggregate(:count)
  end

  ## Writing

  # Everybody the message is between: its author and everybody it names.
  defp participants(%Status{id: id, account_id: author_id}) do
    mentioned =
      from(m in Mention, where: m.status_id == ^id, select: m.account_id) |> Repo.all()

    Enum.uniq([author_id | mentioned])
  end

  # An upsert on the identity index, so two messages arriving at the same
  # moment find the same row instead of racing to create two. The status id
  # goes into a set: a job that runs twice must not put it in twice.
  #
  # Unread for everybody but the author, who does not need telling about their
  # own message, and never for a muted thread.
  defp upsert(account_id, status, others) do
    now = DateTime.utc_now()
    unread = account_id != status.account_id

    Repo.insert_all(
      "account_conversations",
      [
        [
          account_id: account_id,
          conversation_id: status.conversation_id,
          participant_account_ids: others,
          status_ids: [status.id],
          last_status_id: status.id,
          unread: unread,
          muted: false,
          inserted_at: now,
          updated_at: now
        ]
      ],
      conflict_target: [:account_id, :conversation_id, :participant_account_ids],
      on_conflict:
        from(c in "account_conversations",
          update: [
            set: [
              status_ids:
                fragment(
                  "(SELECT array_agg(DISTINCT s ORDER BY s) FROM unnest(? || ?) AS s)",
                  c.status_ids,
                  ^[status.id]
                ),
              last_status_id: fragment("GREATEST(?, ?)", c.last_status_id, ^status.id),
              unread: fragment("? OR (? AND NOT ?)", c.unread, ^unread, c.muted),
              updated_at: ^now
            ]
          ]
        )
    )

    :ok
  end

  # The row as it now stands, to whoever it belongs to. Rendered by the socket
  # rather than here, the same way a notification is: one broadcast reaching
  # several connections is one payload each of them narrows, and rendering an
  # API entity is not this module's business.
  defp announce(account_id) do
    case latest_row(account_id) do
      nil -> :ok
      row -> Streaming.publish_conversation(account_id, row)
    end
  end

  defp latest_row(account_id) do
    from(c in "account_conversations",
      where: c.account_id == ^account_id,
      order_by: [desc: c.last_status_id],
      limit: 1,
      select: %{
        id: c.id,
        account_id: c.account_id,
        conversation_id: c.conversation_id,
        participant_account_ids: c.participant_account_ids,
        status_ids: c.status_ids,
        last_status_id: c.last_status_id,
        unread: c.unread,
        muted: c.muted
      }
    )
    |> Repo.one()
  end

  defp set(%Account{id: id}, row_id, changes), do: set(id, row_id, changes)

  defp set(account_id, row_id, changes) do
    with {:ok, row_id} <- Snowflake.cast(row_id),
         {1, _} <-
           from(c in "account_conversations",
             where: c.account_id == ^account_id and c.id == ^row_id
           )
           |> Repo.update_all(set: changes ++ [updated_at: DateTime.utc_now()]) do
      {:ok, get(account_id, row_id)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp before_cursor(query, nil), do: query
  defp before_cursor(query, id), do: where(query, [c], c.last_status_id < ^id)

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, id), do: where(query, [c], c.last_status_id > ^id)
end
