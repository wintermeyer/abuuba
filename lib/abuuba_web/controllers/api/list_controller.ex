defmodule AbuubaWeb.API.ListController do
  @moduledoc """
  `/api/v1/lists`.

  A list is somebody's own way of reading what they already receive, so every
  lookup here is scoped to the owner rather than checked afterwards: a query
  that cannot return a stranger's list cannot leak one.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Lists
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.API.NestedParams
  alias AbuubaWeb.API.Pagination

  plug AbuubaWeb.Plugs.RequireUser

  plug AbuubaWeb.Plugs.RequireScopes, ["read:lists"] when action in [:index, :show, :accounts]

  plug AbuubaWeb.Plugs.RequireScopes,
       ["write:lists"] when action in [:create, :update, :delete, :add_accounts, :remove_accounts]

  def index(conn, _params) do
    json(conn, Enum.map(Lists.all(current_account(conn)), &Entities.list/1))
  end

  def show(conn, %{"id" => id}) do
    with_list(conn, id, fn list -> json(conn, Entities.list(list)) end)
  end

  def create(conn, params) do
    case Lists.create(current_account(conn), params) do
      {:ok, list} -> json(conn, Entities.list(list))
      {:error, changeset} -> invalid(conn, changeset)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with_list(conn, id, fn list ->
      case Lists.update(list, params) do
        {:ok, updated} -> json(conn, Entities.list(updated))
        {:error, changeset} -> invalid(conn, changeset)
      end
    end)
  end

  def delete(conn, %{"id" => id}) do
    with_list(conn, id, fn list ->
      {:ok, _} = Lists.delete(list)

      json(conn, %{})
    end)
  end

  def accounts(conn, %{"id" => id} = params) do
    account = current_account(conn)

    with_list(conn, id, fn list ->
      members = Lists.members(list, Pagination.params(params, default: 40))

      conn
      |> Pagination.put_link_header(members)
      |> json(Entities.accounts(members, account))
    end)
  end

  def add_accounts(conn, %{"id" => id} = params) do
    with_list(conn, id, fn list ->
      case Lists.add(list, account_ids(params)) do
        :ok ->
          json(conn, %{})

        # A list is a way of reading what you already receive, so this is not
        # arbitrary strictness: adding somebody you do not follow would be a
        # follow with none of a follow's consequences.
        {:error, :not_following} ->
          API.error(conn, 422, "Validation failed: you have to follow them first")
      end
    end)
  end

  def remove_accounts(conn, %{"id" => id} = params) do
    with_list(conn, id, fn list ->
      :ok = Lists.remove(list, account_ids(params))

      json(conn, %{})
    end)
  end

  defp with_list(conn, id, fun) do
    case Lists.get(current_account(conn), API.id_param(%{"id" => id}, "id")) do
      nil -> API.error(conn, 404, "Record not found")
      list -> fun.(list)
    end
  end

  defp account_ids(params) do
    params
    |> Map.get("account_ids", [])
    |> NestedParams.list()
    |> Enum.map(&API.id_param(%{"id" => &1}, "id"))
    |> Enum.reject(&is_nil/1)
  end

  defp invalid(conn, changeset) do
    API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
  end
end
