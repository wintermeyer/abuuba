defmodule AbuubaWeb.API.ReportController do
  @moduledoc """
  `POST /api/v1/reports`.

  Filing one is all a client can do here. Reading the queue, assigning and
  resolving belong to the admin API, because they are a moderator's work and
  this endpoint is reachable by everybody.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Moderation.Report
  alias Abuuba.Moderation.Reports
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.API.NestedParams

  plug AbuubaWeb.Plugs.RequireUser

  plug AbuubaWeb.Plugs.RequireScopes, ["write:reports"] when action in [:create]

  def create(conn, params) do
    reporter = current_account(conn)

    with %Account{} = target <- target(params),
         {:ok, report} <- Reports.create(reporter, attrs(params, target)) do
      json(conn, Entities.report(report))
    else
      {:error, :rate_limited} ->
        API.error(conn, 429, "Too many requests")

      {:error, %Ecto.Changeset{} = changeset} ->
        API.error(conn, 422, changeset_message(changeset))

      _ ->
        API.error(conn, 404, "Record not found")
    end
  end

  defp target(params) do
    params |> Map.get("account_id") |> API.parse_id() |> account()
  end

  defp account(nil), do: nil
  defp account(id), do: Accounts.get_account(id)

  defp attrs(params, target) do
    %{
      "target_account_id" => target.id,
      "comment" => Map.get(params, "comment", ""),
      "category" => category(params),
      "rule_ids" => params |> Map.get("rule_ids", []) |> NestedParams.list(),
      "status_ids" => params |> Map.get("status_ids", []) |> NestedParams.list(),
      # Never assumed. Forwarding tells the other server who complained.
      "forward" => Map.get(params, "forward") in [true, "true"]
    }
  end

  # An unknown category is "other" rather than a refusal: the report itself is
  # what matters, and a client sending a category this server has not heard of
  # should not lose somebody's complaint over it.
  defp category(params) do
    case Map.get(params, "category") do
      value when value in ~w(other spam legal violation) -> value
      _ -> "other"
    end
  end

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join(", ", fn {field, [message | _]} -> "#{field} #{message}" end)
    |> then(&"Validation failed: #{&1}")
  end

  @doc false
  def report_categories, do: Report.categories()
end
