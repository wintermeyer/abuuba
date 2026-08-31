defmodule Abuuba.Accounts.Suggestions do
  @moduledoc """
  People a reader might want to follow.

  ## Friends of friends, and nothing cleverer

  The accounts followed by the accounts somebody already follows, ordered by
  how many of their follows agree. That is the one signal this server has that
  a person actually chose: it is made of decisions their own circle took, not
  of what is popular on the server or of anything anybody paid for.

  Deliberately not a ranking of the whole instance. A directory of everybody is
  the directory, which exists; a suggestion is supposed to be about the reader.

  ## Nobody appears who has not asked to be found

  `Abuuba.Accounts.listable/1` decides the first half -- discoverable, not
  suspended, not limited, not migrated away -- and this list adds the reader's
  own answers: never somebody blocked, muted, already followed, or the reader
  themselves. A suggestion that names somebody the reader has blocked is the
  server arguing with them.

  Blocks count in both directions, which they did not at first: an account that
  had blocked the reader was still being offered to them, and a block exists to
  stop exactly that. Somebody the reader has a follow request outstanding with
  is out too, along with anybody on a server the reader has blocked personally.
  Each of the three is the reader having already answered the question the card
  asks.

  ## Dismissals are remembered

  The list is computed, so "not this one" has to be written down or the card
  reappears on the next load and the button reads as broken.
  """

  import Ecto.Query

  # Settings rather than a table: it is a short list an admin curates by hand,
  # and a table for it would be four files to say "these few, not those".
  @suppressed_setting "suppressed_suggestions"

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.SuggestionDismissal
  alias Abuuba.Relationships.Block
  alias Abuuba.Relationships.DomainBlock
  alias Abuuba.Relationships.Follow
  alias Abuuba.Relationships.FollowRequest
  alias Abuuba.Relationships.Mute
  alias Abuuba.Repo
  alias Abuuba.Settings

  @doc """
  Accounts worth suggesting to this reader, best first.
  """
  @spec for_account(Account.t() | integer(), keyword()) :: [Account.t()]
  def for_account(account, opts \\ [])
  def for_account(%Account{id: id}, opts), do: for_account(id, opts)

  def for_account(account_id, opts) do
    limit = Keyword.get(opts, :limit, 40)
    offset = Keyword.get(opts, :offset, 0)

    mine = from(f in Follow, where: f.account_id == ^account_id, select: f.target_account_id)

    from(f in Follow,
      join: a in Account,
      as: :account,
      on: a.id == f.target_account_id,
      where: f.account_id in subquery(mine),
      where: f.target_account_id != ^account_id,
      where: f.target_account_id not in subquery(mine),
      where: f.target_account_id not in ^suppressed(),
      where: f.target_account_id not in subquery(dismissed(account_id)),
      where: f.target_account_id not in subquery(hidden(Block, account_id)),
      where: f.target_account_id not in subquery(hidden(Mute, account_id)),
      where: f.target_account_id not in subquery(blocked_by(account_id)),
      where: f.target_account_id not in subquery(already_asked(account_id)),
      where: is_nil(a.domain) or a.domain not in subquery(blocked_domains(account_id)),
      group_by: a.id,
      # Most agreement first, and the newest account as the tie-break, so a
      # reader who comes back tomorrow is not shown the same four faces.
      order_by: [desc: count(f.account_id), desc: a.id],
      limit: ^limit,
      offset: ^offset,
      select: a
    )
    |> Accounts.listable()
    |> Repo.all()
  end

  @doc """
  Stops suggesting somebody, for good.
  """
  @spec dismiss(Account.t() | integer(), integer() | nil) :: :ok
  def dismiss(%Account{id: id}, target_account_id), do: dismiss(id, target_account_id)
  def dismiss(_account_id, nil), do: :ok

  def dismiss(account_id, target_account_id) do
    # The row names an account, so an id that is not there is a foreign key
    # violation rather than a no-op -- and a stale suggestion in an app, or a
    # second tap on a button, is an ordinary thing for a client to send. There
    # is nothing to stop suggesting either way, so this is done rather than
    # refused.
    if Repo.exists?(from(a in Account, where: a.id == ^target_account_id)) do
      write_dismissal(account_id, target_account_id)
    else
      :ok
    end
  end

  defp write_dismissal(account_id, target_account_id) do
    now = DateTime.utc_now()

    Repo.insert_all(
      SuggestionDismissal,
      [
        %{
          account_id: account_id,
          target_account_id: target_account_id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:account_id, :target_account_id]
    )

    :ok
  end

  defp dismissed(account_id) do
    from(d in SuggestionDismissal,
      where: d.account_id == ^account_id,
      select: d.target_account_id
    )
  end

  defp hidden(schema, account_id) do
    from(e in schema, where: e.account_id == ^account_id, select: e.target_account_id)
  end

  # The other direction of the same block. Every timeline checks both, and this
  # query checked only the one the reader made -- so somebody who had blocked
  # the reader was offered to them as a person to follow, which is precisely
  # what a block exists to prevent.
  defp blocked_by(account_id) do
    from(b in Block, where: b.target_account_id == ^account_id, select: b.account_id)
  end

  # A follow already asked for and not yet answered. The card would render a
  # Follow button on somebody the reader has been waiting on for a week.
  defp already_asked(account_id) do
    from(r in FollowRequest, where: r.account_id == ^account_id, select: r.target_account_id)
  end

  # The reader's own domain blocks, not the instance's: somebody who has
  # refused a whole server should not be handed one of its accounts.
  defp blocked_domains(account_id) do
    from(d in DomainBlock, where: d.account_id == ^account_id, select: d.domain)
  end

  @doc """
  The accounts an admin has taken out of everybody's suggestions.

  Not a block and not a silence: the account carries on exactly as before and
  nobody is told. It is for the account this server would rather not put in
  front of a newcomer — a bot with a thousand followers, somebody who asked not
  to be suggested — where the alternative is a moderation action out of all
  proportion to the problem.
  """
  @spec suppressed() :: [integer()]
  def suppressed do
    case Settings.get(@suppressed_setting) do
      list when is_list(list) -> Enum.map(list, &to_integer/1)
      _ -> []
    end
  end

  @doc """
  Takes one out of everybody's suggestions, or puts it back.
  """
  @spec suppress(Account.t() | integer(), boolean()) :: :ok
  def suppress(%Account{id: id}, on?), do: suppress(id, on?)

  def suppress(account_id, on?) do
    account_id = to_integer(account_id)
    current = suppressed()

    updated =
      if on?,
        do: Enum.uniq([account_id | current]),
        else: Enum.reject(current, &(&1 == account_id))

    Settings.put(@suppressed_setting, updated)
  end

  @doc """
  Whether one account is suppressed.
  """
  @spec suppressed?(Account.t() | integer()) :: boolean()
  def suppressed?(%Account{id: id}), do: suppressed?(id)
  def suppressed?(account_id), do: to_integer(account_id) in suppressed()

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> number
      _ -> 0
    end
  end
end
