defmodule AbuubaWeb.API.CuratedListController do
  @moduledoc """
  `/api/v1/collections`, the lists of accounts somebody publishes.

  "People I know who write about gardening", handed to a newcomer as one link
  instead of twelve names typed out in a pinned post.

  Named for what it holds rather than for its path, because
  `AbuubaWeb.API.CollectionController` is already the lists of *posts* a reader
  has kept, and two modules called the same thing in the same namespace is how
  somebody edits the wrong one.

  ## Who may do what

  Making, changing and deleting one is the owner's. Adding somebody to it is
  the owner's. Taking yourself off one is *yours*, whoever made it — that is
  what `revoke` is for, and it is the only thing a person who did not make a
  list may do to it.

  ## Reading one needs nothing

  A collection is published. Its point is to be handed to somebody who has not
  signed up yet, so no token is required to read one.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts
  alias Abuuba.Collections
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities

  plug AbuubaWeb.Plugs.RequireUser
       when action in [:create, :update, :delete, :add_item, :delete_item, :revoke_item]

  plug AbuubaWeb.Plugs.RequireScopes,
       ["write:accounts"]
       when action in [:create, :update, :delete, :add_item, :delete_item, :revoke_item]

  def show(conn, %{"id" => id}) do
    with_collection(conn, id, fn collection -> json(conn, Entities.collection(collection)) end)
  end

  def create(conn, params) do
    case Collections.create(current_account(conn), params) do
      {:ok, collection} ->
        json(conn, Entities.collection(collection))

      {:error, :too_many} ->
        API.error(conn, 422, "Validation failed: you already have as many collections as allowed")

      {:error, changeset} ->
        API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
    end
  end

  def update(conn, %{"id" => id} = params) do
    with_own_collection(conn, id, fn collection ->
      case Collections.update(collection, params) do
        {:ok, updated} ->
          json(conn, Entities.collection(updated))

        {:error, changeset} ->
          API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
      end
    end)
  end

  def delete(conn, %{"id" => id}) do
    with_own_collection(conn, id, fn collection ->
      Collections.delete(collection)

      json(conn, %{})
    end)
  end

  @doc """
  Puts somebody on the list.
  """
  def add_item(conn, %{"collection_id" => id} = params) do
    with_own_collection(conn, id, fn collection ->
      case Accounts.get_account(API.parse_id(params["account_id"]) || 0) do
        nil -> API.error(conn, 404, "Record not found")
        account -> add(conn, collection, account)
      end
    end)
  end

  @doc """
  Takes somebody off it, at the owner's hand.
  """
  def delete_item(conn, %{"collection_id" => id, "id" => item_id}) do
    with_own_collection(conn, id, fn collection ->
      case Collections.get_item(collection, item_id) do
        nil ->
          API.error(conn, 404, "Record not found")

        item ->
          :ok = Collections.remove(item)

          json(conn, %{})
      end
    end)
  end

  @doc """
  Takes yourself off it, whoever made it.

  The one thing somebody who did not make a list may do to it, and it is
  permanent: the row stays as a revoked one so they cannot be added again by
  whoever did not take the hint.
  """
  def revoke_item(conn, %{"collection_id" => id, "id" => item_id}) do
    account = current_account(conn)

    with collection when not is_nil(collection) <- Collections.get(id),
         item when not is_nil(item) <- Collections.get_item(collection, item_id),
         true <- item.account_id == account.id do
      :ok = Collections.revoke(item)

      json(conn, %{})
    else
      false -> API.error(conn, 403, "That is not you")
      _ -> API.error(conn, 404, "Record not found")
    end
  end

  @doc """
  The collections one account publishes.
  """
  def by_account(conn, %{"account_id" => id}) do
    with_account(conn, id, fn account ->
      json(conn, Entities.collections(Collections.by_account(account)))
    end)
  end

  @doc """
  The collections one account appears on.
  """
  def containing_account(conn, %{"account_id" => id}) do
    with_account(conn, id, fn account ->
      json(conn, Entities.collections(Collections.containing(account)))
    end)
  end

  ## Plumbing

  defp add(conn, collection, account) do
    case Collections.add(collection, account) do
      {:ok, item} ->
        json(conn, Entities.collection_item(item))

      {:error, :full} ->
        API.error(conn, 422, "Validation failed: this collection is full")

      {:error, :revoked} ->
        API.error(conn, 422, "Validation failed: they have taken themselves off this collection")

      {:error, _changeset} ->
        API.error(conn, 422, "Validation failed: they are already on this collection")
    end
  end

  defp with_collection(conn, id, fun) do
    case Collections.get(id) do
      nil -> API.error(conn, 404, "Record not found")
      collection -> fun.(collection)
    end
  end

  defp with_own_collection(conn, id, fun) do
    account = current_account(conn)

    with_collection(conn, id, fn collection ->
      if collection.account_id == account.id do
        fun.(collection)
      else
        API.error(conn, 404, "Record not found")
      end
    end)
  end

  defp with_account(conn, id, fun) do
    case Accounts.get_account(API.parse_id(id) || 0) do
      %{suspended_at: nil} = account -> fun.(account)
      _ -> API.error(conn, 404, "Record not found")
    end
  end
end
