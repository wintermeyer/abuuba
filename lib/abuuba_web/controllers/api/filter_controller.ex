defmodule AbuubaWeb.API.FilterController do
  @moduledoc """
  `/api/v2/filters`, and the flat keyword routes beside it.

  The v2 shape is a filter carrying its keywords, because that is how somebody
  writes one: a rule is not a rule until it says which words it means. The flat
  routes exist because a client editing one spelling should not have to send
  the whole rule back.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Filters
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities

  plug AbuubaWeb.Plugs.RequireUser

  plug AbuubaWeb.Plugs.RequireScopes,
       ["read:filters"]
       when action in [:index, :show, :keywords, :show_keyword, :statuses, :show_status]

  plug AbuubaWeb.Plugs.RequireScopes,
       ["write:filters"]
       when action in [
              :create,
              :update,
              :delete,
              :add_keyword,
              :update_keyword,
              :delete_keyword,
              :add_status,
              :delete_status
            ]

  def index(conn, _params) do
    json(conn, Enum.map(Filters.all(current_account(conn)), &Entities.filter/1))
  end

  def show(conn, %{"id" => id}) do
    with_filter(conn, id, fn filter -> json(conn, Entities.filter(filter)) end)
  end

  def create(conn, params) do
    case Filters.create(current_account(conn), params) do
      {:ok, filter} -> json(conn, Entities.filter(filter))
      {:error, changeset} -> invalid(conn, changeset)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with_filter(conn, id, fn filter ->
      case Filters.update(filter, params) do
        {:ok, updated} -> json(conn, Entities.filter(updated))
        {:error, changeset} -> invalid(conn, changeset)
      end
    end)
  end

  def delete(conn, %{"id" => id}) do
    with_filter(conn, id, fn filter ->
      # Not matched on: two clients deleting the same rule is two clients
      # getting what they asked for, and the second must not be a crash.
      Filters.delete(filter)

      json(conn, %{})
    end)
  end

  ## One spelling at a time

  def keywords(conn, %{"filter_id" => id}) do
    with_filter(conn, id, fn filter ->
      json(conn, Enum.map(filter.keywords, &Entities.filter_keyword/1))
    end)
  end

  def add_keyword(conn, %{"filter_id" => id} = params) do
    with_filter(conn, id, fn filter ->
      case Filters.add_keyword(filter, params) do
        {:ok, keyword} -> json(conn, Entities.filter_keyword(keyword))
        {:error, changeset} -> invalid(conn, changeset)
      end
    end)
  end

  def show_keyword(conn, %{"id" => id}) do
    with_keyword(conn, id, fn keyword -> json(conn, Entities.filter_keyword(keyword)) end)
  end

  def update_keyword(conn, %{"id" => id} = params) do
    with_keyword(conn, id, fn keyword ->
      case Filters.update_keyword(keyword, params) do
        {:ok, updated} -> json(conn, Entities.filter_keyword(updated))
        {:error, changeset} -> invalid(conn, changeset)
      end
    end)
  end

  ## One post at a time

  @doc """
  The posts a filter catches by name.

  For the one that gets past the words: a rule about a television programme
  cannot catch the post that talks about it without naming it, and a keyword
  cannot say "that one".
  """
  def statuses(conn, %{"filter_id" => id}) do
    with_filter(conn, id, fn filter ->
      json(conn, Enum.map(Filters.statuses(filter), &Entities.filter_status/1))
    end)
  end

  def add_status(conn, %{"filter_id" => id} = params) do
    with_filter(conn, id, fn filter ->
      case Filters.add_status(filter, params) do
        {:ok, filter_status} -> json(conn, Entities.filter_status(filter_status))
        {:error, changeset} -> invalid(conn, changeset)
      end
    end)
  end

  def show_status(conn, %{"id" => id}) do
    with_filter_status(conn, id, fn filter_status ->
      json(conn, Entities.filter_status(filter_status))
    end)
  end

  def delete_status(conn, %{"id" => id}) do
    with_filter_status(conn, id, fn filter_status ->
      Filters.delete_status(filter_status)

      json(conn, %{})
    end)
  end

  defp with_filter_status(conn, id, fun) do
    case Filters.get_status(current_account(conn), API.parse_id(id)) do
      nil -> API.error(conn, 404, "Record not found")
      filter_status -> fun.(filter_status)
    end
  end

  def delete_keyword(conn, %{"id" => id}) do
    with_keyword(conn, id, fn keyword ->
      Filters.delete_keyword(keyword)

      json(conn, %{})
    end)
  end

  defp with_filter(conn, id, fun) do
    case Filters.get(current_account(conn), API.parse_id(id)) do
      nil -> API.error(conn, 404, "Record not found")
      filter -> fun.(filter)
    end
  end

  defp with_keyword(conn, id, fun) do
    case Filters.get_keyword(current_account(conn), API.parse_id(id)) do
      nil -> API.error(conn, 404, "Record not found")
      keyword -> fun.(keyword)
    end
  end

  defp invalid(conn, changeset) do
    API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
  end
end
