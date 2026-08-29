defmodule AbuubaWeb.CollectionLive do
  @moduledoc """
  The public page for a curated list of accounts.

  The whole point of a collection is that it can be handed to somebody who has
  not signed up anywhere yet, so this renders on the server for a reader with
  no session and no JavaScript, and carries the preview tags a chat window
  reads when the link is pasted into one.

  A list its owner has marked undiscoverable is still reachable by its address:
  undiscoverable means "do not list this for strangers to browse", not "refuse
  it to somebody holding the link". Somebody who was sent it was sent it.
  """

  use AbuubaWeb, :live_view

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Collections
  alias Abuuba.Statuses.Formatter
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.Meta

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    case Collections.get(id) do
      nil ->
        raise AbuubaWeb.NotFound, "no such collection"

      collection ->
        viewer = current_account(socket)
        owner = Accounts.get_account(collection.account_id)

        {:ok,
         socket
         |> assign(
           collection: collection,
           owner: owner,
           accounts: listed_accounts(collection, viewer),
           page_title: collection.name,
           robots: Meta.noindex()
         )
         |> put_meta(collection, owner)}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <header class="border-b border-base-300 p-4">
        <p class="text-xs uppercase text-base-content/60">{gettext("Collection")}</p>
        <h1 class="text-2xl font-semibold">{@collection.name}</h1>

        <p :if={@collection.description not in [nil, ""]} class="mt-2 break-words">
          {@collection.description}
        </p>

        <p class="mt-2 text-sm text-base-content/60">
          {gettext("By")}
          <.link navigate={~p"/@#{@owner.username}"} class="link link-hover">
            @{Account.acct(@owner)}
          </.link>
          · {ngettext("%{count} account", "%{count} accounts", @collection.item_count)}
        </p>

        <p :if={@collection.tag} class="mt-2">
          <.link navigate={~p"/tags/#{@collection.tag.name}"} class="badge badge-ghost">
            #{@collection.tag.name}
          </.link>
        </p>
      </header>

      <ul class="divide-y divide-base-300">
        <li :for={account <- @accounts} class="p-4">
          <.link navigate={~p"/@#{account.username}"} class="font-medium link link-hover">
            {display_name(account)}
          </.link>
          <p class="text-sm text-base-content/60">@{Account.acct(account)}</p>
          <p :if={account.note not in [nil, ""]} class="mt-1 break-words text-sm">
            {raw(note_html(account))}
          </p>
        </li>
      </ul>

      <p :if={@accounts == []} class="p-8 text-center text-base-content/60">
        {gettext("Nobody is on this list yet.")}
      </p>
    </Layouts.app>
    """
  end

  # Suspended accounts are left out rather than shown as a name and nothing
  # else: a list recommending somebody this server has taken down is the one
  # thing it must stop doing on its owner's behalf.
  defp listed_accounts(collection, _viewer) do
    items = Collections.items(collection)
    accounts = items |> Enum.map(& &1.account_id) |> Accounts.get_accounts()

    # In the order the owner put them, which is the order the list means.
    items
    |> Enum.map(&Map.get(accounts, &1.account_id))
    |> Enum.reject(&(&1 == nil or &1.suspended_at != nil))
  end

  defp display_name(%Account{display_name: name}) when name not in [nil, ""], do: name
  defp display_name(%Account{username: username}), do: username

  defp note_html(%Account{domain: nil, note: note}), do: Formatter.to_html(note)
  defp note_html(%Account{note: note}), do: Formatter.sanitize(note)

  defp put_meta(socket, collection, owner) do
    summary =
      if collection.description in [nil, ""],
        do: gettext("A collection by %{name}", name: Account.acct(owner)),
        else: collection.description

    assign(socket, :page_meta, [
      {"property", "og:type", "article"},
      {"property", "og:title", collection.name},
      {"property", "og:description", summary},
      {"property", "og:url", Entities.collection(collection)["url"]},
      {"name", "description", summary}
    ])
  end
end
