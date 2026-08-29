defmodule AbuubaWeb.API.AnnualReportController do
  @moduledoc """
  `/api/v1/annual_reports`, the year in review.

  `index` answers with the reports somebody has not looked at yet, which is
  what a client polls in December to decide whether to show the card at all.
  Everything else is about one report.
  """

  use AbuubaWeb, :controller

  alias Abuuba.AnnualReports
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities

  plug AbuubaWeb.Plugs.RequireUser

  plug AbuubaWeb.Plugs.RequireScopes, ["read:accounts"] when action in [:index, :show, :state]
  plug AbuubaWeb.Plugs.RequireScopes, ["write:accounts"] when action in [:generate, :read]

  def index(conn, _params) do
    account = current_account(conn)

    json(conn, Entities.annual_reports(AnnualReports.pending(account), account))
  end

  def show(conn, %{"id" => id}) do
    account = current_account(conn)

    with_report(conn, id, fn report ->
      json(conn, Entities.annual_reports([report], account))
    end)
  end

  @doc """
  Where a report stands, so a client knows whether to offer to make one.
  """
  def state(conn, %{"id" => id}) do
    account = current_account(conn)

    case Integer.parse(to_string(id)) do
      {year, ""} -> json(conn, %{"state" => AnnualReports.state(account, year)})
      _ -> API.error(conn, 404, "Record not found")
    end
  end

  @doc """
  Builds one for a year, if this is the fortnight for it.

  Answers with the report either way when there is one, so a client that asks
  twice gets the same answer rather than an error the second time.
  """
  def generate(conn, %{"id" => id}) do
    account = current_account(conn)

    with {year, ""} <- Integer.parse(to_string(id)),
         "available" <- ready(account, year) do
      json(conn, Entities.annual_reports([AnnualReports.for_year(account, year)], account))
    else
      "eligible" -> API.error(conn, 422, "Validation failed: that year is not ready to generate")
      "ineligible" -> API.error(conn, 422, "Validation failed: there is no report for that year")
      _ -> API.error(conn, 404, "Record not found")
    end
  end

  @doc """
  Records that its owner has read it, so the card stops being offered.
  """
  def read(conn, %{"id" => id}) do
    with_report(conn, id, fn report ->
      {:ok, _report} = AnnualReports.mark_read(report)

      json(conn, %{})
    end)
  end

  defp ready(account, year) do
    case AnnualReports.state(account, year) do
      "eligible" ->
        case AnnualReports.generate(account, year) do
          {:ok, _report} -> "available"
          {:error, _reason} -> "eligible"
        end

      state ->
        state
    end
  end

  defp with_report(conn, id, fun) do
    case AnnualReports.get(current_account(conn), id) do
      nil -> API.error(conn, 404, "Record not found")
      report -> fun.(report)
    end
  end
end
