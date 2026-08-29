defmodule Abuuba.Lists do
  @moduledoc """
  Named subsets of the people somebody follows.

  Membership is restricted to accounts the owner already follows, which is not
  arbitrary: a list is a way of reading what you already receive, so putting
  somebody in one you do not follow would silently turn it into a follow with
  none of the consequences of one.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Lists.List, as: AccountList
  alias Abuuba.Relationships
  alias Abuuba.Repo

  @doc """
  Somebody's lists, by title.
  """
  @spec all(Account.t() | integer()) :: [AccountList.t()]
  def all(%Account{id: id}), do: all(id)

  def all(account_id) do
    AccountList
    |> where([l], l.account_id == ^account_id)
    |> order_by([l], asc: l.title)
    |> Repo.all()
  end

  @doc """
  One of somebody's lists, or `nil`. Scoped to the owner, so a query cannot
  return a stranger's.
  """
  @spec get(Account.t() | integer(), integer() | nil) :: AccountList.t() | nil
  def get(%Account{id: id}, list_id), do: get(id, list_id)
  def get(_account_id, nil), do: nil
  def get(account_id, list_id), do: Repo.get_by(AccountList, id: list_id, account_id: account_id)

  @doc """
  Creates one.
  """
  @spec create(Account.t(), map()) :: {:ok, AccountList.t()} | {:error, Ecto.Changeset.t()}
  def create(%Account{id: account_id}, attrs) do
    %AccountList{}
    |> AccountList.changeset(Map.put(normalise(attrs), "account_id", account_id))
    |> Repo.insert()
  end

  @doc """
  Renames one, or changes how it treats replies.
  """
  @spec update(AccountList.t(), map()) :: {:ok, AccountList.t()} | {:error, Ecto.Changeset.t()}
  def update(%AccountList{} = list, attrs) do
    list |> AccountList.changeset(normalise(attrs)) |> Repo.update()
  end

  @doc """
  Deletes one. The people in it are unaffected; a list is a way of reading, not
  a relationship.
  """
  @spec delete(AccountList.t()) :: {:ok, AccountList.t()} | {:error, Ecto.Changeset.t()}
  def delete(%AccountList{} = list), do: Repo.delete(list)

  @doc """
  Who is in a list.
  """
  @spec members(AccountList.t(), map()) :: [Account.t()]
  def members(%AccountList{id: list_id}, page \\ %{}) do
    Account
    |> join(:inner, [a], m in "list_accounts", on: m.account_id == a.id)
    |> where([_a, m], m.list_id == ^list_id)
    |> order_by([a], desc: a.id)
    |> limit(^Map.get(page, :limit, 40))
    |> Repo.all()
  end

  @doc """
  Adds people to a list.

  Only accounts the owner already follows. A list is a way of reading what you
  already receive, so adding somebody you do not follow would be a follow with
  none of a follow's consequences: they would never be told, and nothing would
  be delivered.
  """
  @spec add(AccountList.t(), [integer()]) :: :ok | {:error, :not_following}
  def add(%AccountList{} = list, account_ids) do
    ids = Enum.uniq(account_ids)

    if Enum.all?(ids, &Relationships.following?(list.account_id, &1)) do
      now = DateTime.utc_now()

      rows =
        Enum.map(ids, fn id ->
          %{list_id: list.id, account_id: id, inserted_at: now, updated_at: now}
        end)

      Enum.each(ids, &Abuuba.Timelines.merge_list_member(list, &1))

      Repo.insert_all("list_accounts", rows,
        on_conflict: :nothing,
        conflict_target: [:list_id, :account_id]
      )

      :ok
    else
      {:error, :not_following}
    end
  end

  @doc """
  Takes people out of a list.
  """
  @spec remove(AccountList.t(), [integer()]) :: :ok
  def remove(%AccountList{id: list_id} = list, account_ids) do
    from(m in "list_accounts", where: m.list_id == ^list_id and m.account_id in ^account_ids)
    |> Repo.delete_all()

    Enum.each(account_ids, &Abuuba.Timelines.unmerge_list_member(list, &1))

    :ok
  end

  @doc """
  Which of somebody's lists an account is in, which is what a client shows on a
  profile.
  """
  @spec containing(Account.t() | integer(), Account.t() | integer()) :: [AccountList.t()]
  def containing(%Account{id: owner_id}, member), do: containing(owner_id, member)
  def containing(owner_id, %Account{id: member_id}), do: containing(owner_id, member_id)

  def containing(owner_id, member_id) do
    AccountList
    |> join(:inner, [l], m in "list_accounts", on: m.list_id == l.id)
    |> where([l, m], l.account_id == ^owner_id and m.account_id == ^member_id)
    |> order_by([l], asc: l.title)
    |> Repo.all()
  end

  @doc """
  Every account in any of somebody's exclusive lists.

  These are the people a home timeline leaves out, which is what makes an
  exclusive list a way of reading less.
  """
  @spec exclusive_member_ids(Account.t() | integer()) :: [integer()]
  def exclusive_member_ids(%Account{id: id}), do: exclusive_member_ids(id)

  def exclusive_member_ids(account_id) do
    AccountList
    |> join(:inner, [l], m in "list_accounts", on: m.list_id == l.id)
    |> where([l], l.account_id == ^account_id and l.exclusive)
    |> select([_l, m], m.account_id)
    |> distinct(true)
    |> Repo.all()
  end

  @doc """
  Which of these people's lists an author is a member of.

  Asked once for a whole fan-out chunk rather than per person, which is the
  point of doing the fan-out in chunks at all. Each list comes back with its
  owner and its `replies_policy`, because the caller has to answer that policy
  and would otherwise ask again per list.
  """
  @spec lists_containing(integer(), [integer()]) :: [
          %{id: integer(), account_id: integer(), replies_policy: String.t()}
        ]
  def lists_containing(_author_id, []), do: []

  def lists_containing(author_id, owner_ids) do
    AccountList
    |> join(:inner, [l], m in "list_accounts", on: m.list_id == l.id)
    |> where([l], l.account_id in ^owner_ids)
    |> where([_l, m], m.account_id == ^author_id)
    |> select([l], %{id: l.id, account_id: l.account_id, replies_policy: l.replies_policy})
    |> distinct(true)
    |> Repo.all()
  end

  @doc """
  Which of these lists have the given account as a member.

  Asked once for every candidate list rather than once per list: a post by
  somebody in a dozen lists would otherwise be a dozen round trips.
  """
  @spec list_ids_with_member([integer()], integer() | nil) :: MapSet.t()
  def list_ids_with_member([], _account_id), do: MapSet.new()
  def list_ids_with_member(_list_ids, nil), do: MapSet.new()

  def list_ids_with_member(list_ids, account_id) do
    from(m in "list_accounts",
      where: m.list_id in ^list_ids and m.account_id == ^account_id,
      select: m.list_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp normalise(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
