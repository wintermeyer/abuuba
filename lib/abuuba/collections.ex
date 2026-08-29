defmodule Abuuba.Collections do
  @moduledoc """
  Lists of accounts somebody publishes, so a newcomer gets one link instead of
  twelve names.

  ## Being on one is opt-out

  Adding a local account accepts it immediately, and that account can revoke it
  afterwards. Asking first sounds kinder and works worse: a list whose twelve
  entries each need answering before anybody sees anything is a list that never
  launches, and the people most worth recommending are the least likely to be
  reading their notifications.

  A revoked item is kept as a revoked row rather than deleted. Somebody who
  took themselves off a list cannot be put back on it by whoever did not take
  the hint, and that only works if the row survives.

  ## The count is on the row

  `item_count` is denormalised because it is on every card in every listing,
  and maintained here so nothing else has to remember. It counts the items a
  reader would be shown, not the rows.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Collections.Collection
  alias Abuuba.Collections.Item
  alias Abuuba.Notifications
  alias Abuuba.Repo
  alias Abuuba.Statuses.Tag

  @doc """
  The collections one account publishes, newest first.
  """
  @spec by_account(Account.t() | integer(), map()) :: [Collection.t()]
  def by_account(account, page \\ %{})
  def by_account(%Account{id: id}, page), do: by_account(id, page)

  def by_account(account_id, page) do
    Collection
    |> where([c], c.account_id == ^account_id)
    |> order_by([c], desc: c.id)
    |> limit(^Map.get(page, :limit, 40))
    |> preload(:tag)
    |> Repo.all()
  end

  @doc """
  The collections one account appears on.

  Only the ones they have not taken themselves off, and only from collections
  their owner has left discoverable: a list somebody keeps to themselves is not
  a fact about the people on it.
  """
  @spec containing(Account.t() | integer(), map()) :: [Collection.t()]
  def containing(account, page \\ %{})
  def containing(%Account{id: id}, page), do: containing(id, page)

  def containing(account_id, page) do
    Collection
    |> join(:inner, [c], i in Item, on: i.collection_id == c.id)
    |> where([_c, i], i.account_id == ^account_id and i.state in ["pending", "accepted"])
    |> where([c], c.discoverable)
    |> order_by([c], desc: c.id)
    |> limit(^Map.get(page, :limit, 40))
    |> preload(:tag)
    |> Repo.all()
  end

  @doc """
  One collection, or `nil`.
  """
  @spec get(term()) :: Collection.t() | nil
  def get(id) do
    case numeric(id) do
      {:ok, id} -> Collection |> where([c], c.id == ^id) |> preload(:tag) |> Repo.one()
      :error -> nil
    end
  end

  @doc """
  The items on one, in the order its owner put them, readable ones only.
  """
  @spec items(Collection.t() | integer()) :: [Item.t()]
  def items(%Collection{id: id}), do: items(id)

  def items(collection_id) do
    Item
    |> where([i], i.collection_id == ^collection_id and i.state in ["pending", "accepted"])
    |> order_by([i], asc: i.position, asc: i.id)
    |> Repo.all()
  end

  @doc """
  One item, or `nil`.
  """
  @spec get_item(Collection.t() | integer(), term()) :: Item.t() | nil
  def get_item(%Collection{id: id}, item_id), do: get_item(id, item_id)

  def get_item(collection_id, item_id) do
    case numeric(item_id) do
      {:ok, id} -> Repo.get_by(Item, id: id, collection_id: collection_id)
      :error -> nil
    end
  end

  @doc """
  Publishes a new one.
  """
  @spec create(Account.t(), map()) ::
          {:ok, Collection.t()} | {:error, Ecto.Changeset.t() | :too_many}
  def create(%Account{id: account_id}, attrs) do
    if count_for(account_id) >= Collection.per_account_max() do
      {:error, :too_many}
    else
      %Collection{}
      |> Collection.owner_changeset(account_id, tag_attrs(attrs))
      |> Repo.insert()
      |> reload()
    end
  end

  @doc """
  Changes one.
  """
  @spec update(Collection.t(), map()) :: {:ok, Collection.t()} | {:error, Ecto.Changeset.t()}
  def update(%Collection{} = collection, attrs) do
    collection
    |> Collection.changeset(tag_attrs(attrs))
    |> Repo.update()
    |> reload()
  end

  @doc """
  Deletes one, and the items with it.
  """
  @spec delete(Collection.t()) :: {:ok, Collection.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Collection{} = collection), do: Repo.delete(collection, stale_error_field: :id)

  @doc """
  Puts an account on a list.

  Refused when the list is full, when the account is already on it, and when
  they took themselves off it before — that last one is the whole point of
  keeping a revoked row.
  """
  @spec add(Collection.t(), Account.t()) ::
          {:ok, Item.t()} | {:error, Ecto.Changeset.t() | :full | :revoked}
  def add(%Collection{} = collection, %Account{} = account) do
    with :ok <- room_for(collection),
         :ok <- not_revoked(collection, account) do
      attrs = %{
        collection_id: collection.id,
        account_id: account.id,
        position: next_position(collection),
        state: "accepted"
      }

      with {:ok, item} <- %Item{} |> Item.changeset(attrs) |> Repo.insert() do
        recount(collection)

        # Told rather than left to notice. Somebody put on a public list has a
        # decision to make about it, and cannot make it without knowing.
        Notifications.notify(account, collection.account_id, "collection_add")

        {:ok, item}
      end
    end
  end

  @doc """
  Takes an item off, at the list owner's hand.
  """
  @spec remove(Item.t()) :: :ok
  def remove(%Item{} = item) do
    Repo.delete(item, stale_error_field: :id)
    recount(item.collection_id)

    :ok
  end

  @doc """
  Takes an item off at the listed account's hand, permanently.

  Kept as a revoked row rather than deleted, so that whoever added them cannot
  simply do it again.
  """
  @spec revoke(Item.t()) :: :ok
  def revoke(%Item{} = item) do
    item |> Ecto.Changeset.change(state: "revoked") |> Repo.update()
    recount(item.collection_id)

    :ok
  end

  @doc """
  Discoverable collections about one of a post's hashtags.

  What a client shows under a post: "there is a list of people who write about
  this". Only collections whose owner left them discoverable, and never more
  than a couple, because it is a footnote rather than a section.
  """
  @spec for_tags([Tag.t()] | [String.t()], keyword()) :: [Collection.t()]
  def for_tags(tags, opts \\ [])
  def for_tags([], _opts), do: []

  def for_tags(tags, opts) do
    names = Enum.map(tags, &tag_name/1)

    Collection
    |> join(:inner, [c], t in Tag, on: t.id == c.tag_id)
    |> where([_c, t], t.name in ^names)
    |> where([c], c.discoverable)
    |> order_by([c], desc: c.item_count, desc: c.id)
    |> limit(^Keyword.get(opts, :limit, 4))
    |> preload(:tag)
    |> Repo.all()
  end

  ## Plumbing

  defp tag_name(%Tag{name: name}), do: name
  defp tag_name(name) when is_binary(name), do: Tag.normalise(name)

  # A client sends the word, not an id: it is picking a hashtag, and the tag
  # row is this server's business rather than the client's.
  defp tag_attrs(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    case attrs["tag"] do
      name when name in [nil, ""] ->
        attrs

      name ->
        case Abuuba.Statuses.upsert_tag(to_string(name)) do
          {:ok, tag} -> Map.put(attrs, "tag_id", tag.id)
          {:error, _changeset} -> Map.put(attrs, "tag_id", nil)
        end
    end
  end

  defp count_for(account_id) do
    Collection |> where([c], c.account_id == ^account_id) |> Repo.aggregate(:count)
  end

  defp room_for(collection) do
    if visible_count(collection.id) >= Collection.items_max(), do: {:error, :full}, else: :ok
  end

  defp not_revoked(collection, account) do
    revoked? =
      Item
      |> where([i], i.collection_id == ^collection.id and i.account_id == ^account.id)
      |> where([i], i.state == "revoked")
      |> Repo.exists?()

    if revoked?, do: {:error, :revoked}, else: :ok
  end

  defp next_position(collection) do
    Item
    |> where([i], i.collection_id == ^collection.id)
    |> select([i], max(i.position))
    |> Repo.one()
    |> case do
      nil -> 1
      highest -> highest + 1
    end
  end

  defp visible_count(collection_id) do
    Item
    |> where([i], i.collection_id == ^collection_id and i.state in ["pending", "accepted"])
    |> Repo.aggregate(:count)
  end

  # What a reader would be shown, not how many rows there are: a list whose
  # card says twelve and shows nine is a card nobody trusts.
  defp recount(%Collection{id: id}), do: recount(id)

  defp recount(collection_id) do
    count = visible_count(collection_id)

    Collection
    |> where([c], c.id == ^collection_id)
    |> Repo.update_all(set: [item_count: count, updated_at: DateTime.utc_now()])

    :ok
  end

  defp reload({:ok, %Collection{id: id}}), do: {:ok, get(id)}
  defp reload(other), do: other

  defp numeric(value) when is_integer(value), do: {:ok, value}

  defp numeric(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp numeric(_value), do: :error
end
