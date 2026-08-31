defmodule AbuubaWeb.API.ScheduledStatusController do
  @moduledoc """
  `/api/v1/scheduled_statuses`.

  Only ever an account's own. A scheduled post is something somebody wrote and
  has not published, so it is nobody else's to read, list or cancel, and the
  lookup is scoped by account rather than checked afterwards: a query that
  cannot return a stranger's row cannot leak one.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Statuses
  alias Abuuba.Statuses.ScheduledStatus
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.API.Pagination

  plug AbuubaWeb.Plugs.RequireUser

  plug AbuubaWeb.Plugs.RequireScopes, ["read:statuses"] when action in [:index, :show]
  plug AbuubaWeb.Plugs.RequireScopes, ["write:statuses"] when action in [:update, :delete]

  def index(conn, params) do
    account = current_account(conn)
    page = Pagination.params(params, default: 20)
    scheduled = account |> Statuses.scheduled() |> Enum.take(page.limit)

    conn
    |> Pagination.put_link_header(scheduled)
    |> json(Entities.scheduled_statuses(scheduled))
  end

  def show(conn, %{"id" => id}) do
    with_own(conn, id, fn scheduled -> json(conn, Entities.scheduled_status(scheduled)) end)
  end

  def update(conn, %{"id" => id} = params) do
    with_own(conn, id, fn scheduled ->
      move(conn, scheduled, parse_time(params["scheduled_at"]))
    end)
  end

  defp move(conn, _scheduled, nil) do
    API.error(conn, 422, "Validation failed: scheduled_at is invalid")
  end

  defp move(conn, scheduled, at) do
    case Statuses.reschedule(scheduled, at) do
      {:ok, updated} -> json(conn, Entities.scheduled_status(updated))
      {:error, _changeset} -> API.error(conn, 422, too_soon())
    end
  end

  def delete(conn, %{"id" => id}) do
    with_own(conn, id, fn scheduled ->
      {:ok, _} = Statuses.cancel_schedule(scheduled)

      json(conn, %{})
    end)
  end

  defp with_own(conn, id, fun) do
    account = current_account(conn)

    case Statuses.get_scheduled(account, API.parse_id(id) || 0) do
      nil -> API.error(conn, 404, "Record not found")
      scheduled -> fun.(scheduled)
    end
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp parse_time(_value), do: nil

  defp too_soon do
    minutes = div(ScheduledStatus.minimum_notice_seconds(), 60)

    "Validation failed: scheduled_at must be at least #{minutes} minutes from now"
  end
end
