defmodule AbuubaWeb.AnnualReportLive do
  @moduledoc """
  The share page for somebody's year in review.

  Public, and safe to be public: every number in a report is worked out from
  public and unlisted posts only, so the page says nothing a visitor could not
  already have counted by scrolling the profile. See `Abuuba.AnnualReports`.

  Rendered on the server with preview tags, because the only reason anybody
  opens this page is that somebody pasted the link somewhere.
  """

  use AbuubaWeb, :live_view

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.AnnualReports
  alias AbuubaWeb.Formats
  alias AbuubaWeb.Meta

  @impl Phoenix.LiveView
  def mount(%{"username" => username, "year" => year}, _session, socket) do
    with %Account{suspended_at: nil} = account <- Accounts.lookup(username),
         report when not is_nil(report) <- AnnualReports.for_year(account, year) do
      {:ok,
       socket
       |> assign(
         account: account,
         report: report,
         page_title: page_title(account, report),
         robots: Meta.noindex()
       )
       |> put_meta(account, report)}
    else
      _ -> raise AbuubaWeb.NotFound, "no such report"
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <header class="border-b border-base-300 p-4">
        <p class="text-xs uppercase text-base-content/60">{@report.year}</p>
        <h1 class="text-2xl font-semibold">
          {gettext("%{name}'s year", name: Account.display_name(@account))}
        </h1>
        <p class="text-base-content/60">
          <.link navigate={~p"/@#{@account.username}"} class="link link-hover">
            @{Account.acct(@account)}
          </.link>
        </p>
      </header>

      <section class="p-4">
        <p class="text-lg">{archetype_line(@report)}</p>

        <dl class="mt-4 grid gap-3 sm:grid-cols-2">
          <div class="rounded-box border border-base-300 p-3">
            <dt class="text-sm text-base-content/60">{gettext("Posts this year")}</dt>
            <dd class="text-2xl font-semibold">{Formats.number(posts_total(@report))}</dd>
          </div>
          <div class="rounded-box border border-base-300 p-3">
            <dt class="text-sm text-base-content/60">{gettext("New followers")}</dt>
            <dd class="text-2xl font-semibold">{Formats.number(followers_total(@report))}</dd>
          </div>
        </dl>

        <div :if={top_hashtags(@report) != []} class="mt-6">
          <h2 class="font-semibold">{gettext("Written about most")}</h2>
          <ul class="mt-2 flex flex-wrap gap-2">
            <li :for={tag <- top_hashtags(@report)}>
              <.link navigate={~p"/tags/#{tag["name"]}"} class="badge badge-ghost">
                #{tag["name"]} · {Formats.number(tag["count"])}
              </.link>
            </li>
          </ul>
        </div>

        <p class="mt-6 text-sm text-base-content/60">
          {gettext("Counted from public posts only.")}
        </p>
      </section>
    </Layouts.app>
    """
  end

  defp page_title(account, report), do: "#{Account.display_name(account)} · #{report.year}"

  defp posts_total(report) do
    report.data |> Map.get("time_series", []) |> Enum.map(&(&1["statuses"] || 0)) |> Enum.sum()
  end

  defp followers_total(report) do
    report.data |> Map.get("time_series", []) |> Enum.map(&(&1["followers"] || 0)) |> Enum.sum()
  end

  defp top_hashtags(report), do: Map.get(report.data, "top_hashtags", [])

  # One sentence rather than a bare word. "oracle" on its own means nothing to
  # somebody who has not read the client's glossary.
  defp archetype_line(report) do
    case Map.get(report.data, "archetype") do
      "lurker" -> gettext("Read a lot more than they wrote.")
      "booster" -> gettext("Mostly here to pass on what other people said.")
      "pollster" -> gettext("Asked a lot of questions.")
      "replier" -> gettext("Spent the year in other people's threads.")
      _ -> gettext("Wrote things other people replied to.")
    end
  end

  defp put_meta(socket, account, report) do
    summary =
      gettext("%{count} posts in %{year}",
        count: Formats.number(posts_total(report)),
        year: report.year
      )

    assign(
      socket,
      :page_meta,
      Meta.open_graph(
        title: page_title(account, report),
        description: summary,
        url: url(~p"/@#{account.username}/year/#{report.year}")
      )
    )
  end
end
