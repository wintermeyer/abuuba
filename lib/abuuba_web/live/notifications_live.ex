defmodule AbuubaWeb.NotificationsLive do
  @moduledoc """
  What happened while somebody was away.

  ## Grouped, because events come in bursts

  Twelve people boosting one post is one thing that happened, not twelve. The
  grouping is the context's (`Abuuba.Notifications.grouped/2`); what is here is
  the sentence each kind of group turns into, which is the part that has to be
  written per type: "followed you" and "boosted" and "mentioned you" are not
  one sentence with a noun swapped out.

  ## The requests inbox is on the page

  Somebody who set a policy to filter has a folder, and a folder nobody can see
  is a folder nobody empties. It sits above the column rather than behind a
  settings screen, because the whole reason it exists is that its contents
  might matter.

  ## Two filters, not one

  A quick All/Mentions switch covers what almost everybody wants and is a link,
  so it is an address that can be sent and returned to. The per-type list is
  for somebody who wants only boosts and has said so, and is remembered,
  because a filter you have to set again every visit is one nobody uses.
  """

  use AbuubaWeb, :live_view

  import AbuubaWeb.StatusComponent

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Notifications
  alias Abuuba.Streaming
  alias Abuuba.Timelines
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.API.NestedParams
  alias AbuubaWeb.Params

  @page_size 40

  # The ones worth offering as a checkbox. The rest are rare enough that a list
  # of fourteen boxes would hide the four somebody actually wanted.
  @offered_types ~w(mention reblog follow follow_request favourite poll update quote status)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    account = current_account(socket)

    if connected?(socket), do: Streaming.subscribe(Streaming.account_topic(account))

    # No `load/1` here: `handle_params/3` always runs right after mount and
    # loads the page, so loading here too would ask everything twice.
    {:ok,
     assign(socket,
       page_title: gettext("Notifications"),
       account: account,
       types: stored_types(socket.assigns.current_scope.user)
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(scope: socket.assigns.live_action) |> load()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <div class="border-b border-base-300">
        <nav class="flex items-center gap-1 px-2" aria-label={gettext("Which notifications")}>
          <.link
            :for={{action, label} <- scopes()}
            navigate={scope_path(action)}
            aria-current={@scope == action && "page"}
            class={["px-3 py-2", @scope == action && "border-b-2 border-primary font-semibold"]}
          >
            {label}
          </.link>

          <span :if={@unread > 0} class="badge badge-primary ml-auto">
            {ngettext("%{count} new", "%{count} new", @unread)}
          </span>
        </nav>

        <form id="notification-types" phx-change="set_types" class="flex flex-wrap gap-3 px-3 pb-2">
          <label :for={type <- offered_types()} class="flex items-center gap-1 text-sm">
            <input
              type="checkbox"
              name="types[]"
              value={type}
              checked={type in @types}
              class="checkbox checkbox-xs"
            />
            {type_label(type)}
          </label>
        </form>

        <div class="flex gap-2 px-3 pb-2">
          <button
            :if={@unread > 0}
            type="button"
            phx-click="mark_read"
            class="btn btn-ghost btn-xs"
          >
            {gettext("Mark as read")}
          </button>

          <button :if={@groups != []} type="button" phx-click="clear_all" class="btn btn-ghost btn-xs">
            {gettext("Clear all")}
          </button>
        </div>
      </div>

      <section :if={@requests != []} class="border-b border-base-300 bg-base-200/40 p-3">
        <h2 class="text-sm font-semibold">
          {ngettext(
            "%{count} person waiting to reach you",
            "%{count} people waiting to reach you",
            length(@requests)
          )}
        </h2>
        <p class="mt-1 text-sm text-base-content/70">
          {gettext("Your settings filed these instead of showing them.")}
        </p>

        <ul class="mt-2 divide-y divide-base-300">
          <li :for={request <- @requests} class="flex items-center gap-2 py-2 text-sm">
            <span class="min-w-0 flex-1 truncate">
              {sender_name(request, @senders)}
              <span class="text-base-content/60">
                {ngettext(
                  "%{count} notification",
                  "%{count} notifications",
                  request.notifications_count
                )}
              </span>
            </span>

            <button
              type="button"
              phx-click="accept_request"
              phx-value-account={request.from_account_id}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Let them through")}
            </button>

            <button
              type="button"
              phx-click="dismiss_request"
              phx-value-account={request.from_account_id}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Not now")}
            </button>
          </li>
        </ul>
      </section>

      <div id="notifications">
        <article
          :for={group <- @groups}
          id={"group-#{dom_id(group.key)}"}
          class="border-b border-base-300 p-4"
        >
          <div class="flex items-baseline gap-2">
            <span class="hero-bell size-4 shrink-0" aria-hidden="true" />
            <p class="min-w-0 flex-1">{headline(group)}</p>

            <button
              type="button"
              phx-click="dismiss"
              phx-value-group={group.key}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Dismiss")}
            </button>
          </div>

          <.status
            :if={group.status}
            id={"group-#{dom_id(group.key)}-status"}
            status={group.status}
            viewer_id={to_string(@account.id)}
          />
        </article>
      </div>

      <p :if={@groups == []} class="p-8 text-center text-base-content/60">
        {gettext("Nothing has happened yet.")}
      </p>
    </Layouts.app>
    """
  end

  ## Events

  @impl Phoenix.LiveView
  def handle_event("set_types", params, socket) do
    types =
      params
      |> Map.get("types", [])
      |> NestedParams.list()
      |> Enum.filter(&(&1 in @offered_types))

    remember(socket, types)

    {:noreply, socket |> assign(types: types) |> load()}
  end

  def handle_event("mark_read", _params, socket) do
    case Notifications.list(socket.assigns.account, %{limit: 1}) do
      [newest | _] -> Timelines.put_marker(socket.assigns.account, "notifications", newest.id)
      [] -> :ok
    end

    {:noreply, load(socket)}
  end

  def handle_event("dismiss", %{"group" => key}, socket) do
    account = socket.assigns.account

    Notifications.dismiss_group(account, key)

    {:noreply, load(socket)}
  end

  def handle_event("clear_all", _params, socket) do
    Notifications.clear(socket.assigns.account)

    {:noreply, load(socket)}
  end

  def handle_event("accept_request", %{"account" => id}, socket) do
    with {:ok, id} <- Params.id(id) do
      Notifications.accept_request(socket.assigns.account, id)
    end

    {:noreply, load(socket)}
  end

  def handle_event("dismiss_request", %{"account" => id}, socket) do
    with {:ok, id} <- Params.id(id) do
      Notifications.dismiss_request(socket.assigns.account, id)
    end

    {:noreply, load(socket)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_info({:streaming, "notification", _notification}, socket) do
    {:noreply, load(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Plumbing

  defp load(socket) do
    account = socket.assigns.account
    page = %{limit: @page_size, types: wanted_types(socket)}
    groups = Notifications.grouped(account, page)
    requests = Notifications.requests(account)

    # Everybody named on the page in one query, every referenced post in one
    # rendering batch. Loading them per group made one arriving notification
    # cost a page of round trips.
    senders = sender_map(groups, requests)
    statuses = status_map(groups, account)

    socket
    |> assign_new(:scope, fn -> :all end)
    |> assign(
      # A notification about a post the reader's own rule said to hide goes
      # with the post. Leaving the row and dropping the post would be the
      # notification saying somebody replied and refusing to say to what.
      groups:
        groups |> Enum.map(&decorate(&1, senders, statuses)) |> Enum.reject(&hidden_group?/1),
      requests: requests,
      senders: senders,
      unread: Notifications.unread_badge(account.id)
    )
  end

  defp sender_map(groups, requests) do
    groups
    |> Enum.flat_map(fn group -> Enum.map(group.notifications, & &1.from_account_id) end)
    |> Kernel.++(Enum.map(requests, & &1.from_account_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Accounts.get_accounts()
  end

  defp status_map(groups, account) do
    groups
    |> Enum.map(fn group -> hd(group.notifications).status_id end)
    |> Entities.statuses_by_id(account, filter_context: "notifications")
  end

  # The quick filter wins. Clicking a tab called Mentions and getting an empty
  # page because of a checkbox somebody set weeks ago is a trap rather than a
  # filter; the tab says what it shows, so it shows that.
  defp wanted_types(%{assigns: %{scope: :mentions}}), do: ["mention"]
  defp wanted_types(socket), do: socket.assigns.types

  # The post is rendered once per group rather than once per notification —
  # twelve boosts of one post are one post — and both the posts and the people
  # come out of the maps `load/1` built for the whole page.
  defp decorate(group, senders, statuses) do
    newest = hd(group.notifications)

    Map.merge(group, %{
      type: newest.type,
      count: length(group.notifications),
      senders:
        group.notifications
        |> Enum.map(& &1.from_account_id)
        |> Enum.uniq()
        |> Enum.flat_map(&List.wrap(senders[&1])),
      status: newest.status_id && statuses[to_string(newest.status_id)]
    })
  end

  defp hidden_group?(%{status: nil}), do: false
  defp hidden_group?(%{status: status}), do: hidden?(status)

  # One sentence per kind. A single sentence with the verb swapped would read
  # wrongly in half the languages this is translated into, and the plural of
  # "one other person" is not a suffix.
  defp headline(%{count: 1, senders: [sender | _]} = group) do
    verb(group.type, Account.display_name(sender))
  end

  defp headline(%{senders: [sender | _]} = group) do
    others(group.type, Account.display_name(sender), group.count)
  end

  defp headline(group), do: verb(group.type, gettext("Somebody"))

  defp verb("mention", name), do: gettext("%{name} mentioned you", name: name)
  defp verb("reblog", name), do: gettext("%{name} boosted your post", name: name)
  defp verb("follow", name), do: gettext("%{name} followed you", name: name)
  defp verb("follow_request", name), do: gettext("%{name} asked to follow you", name: name)
  defp verb("favourite", name), do: gettext("%{name} favourited your post", name: name)
  defp verb("poll", name), do: gettext("A poll by %{name} has ended", name: name)
  defp verb("update", name), do: gettext("%{name} edited a post you boosted", name: name)
  defp verb("status", name), do: gettext("%{name} posted", name: name)
  defp verb("quote", name), do: gettext("%{name} quoted your post", name: name)
  # The ones the server or a moderator sends, which name no sender the reader
  # needs. A moderation warning in particular used to read "Something happened
  # involving <moderator>": nothing a person can act on, about somebody whose
  # name is not their business.
  defp verb("moderation_warning", _name),
    do: gettext("Your account has received a moderation warning")

  defp verb("severed_relationships", _name),
    do:
      gettext(
        "Some of your follows were removed when this server stopped federating with another"
      )

  defp verb("annual_report", _name), do: gettext("Your year on this server is ready to read")

  defp verb("collection_add", name),
    do: gettext("%{name} added your post to a collection", name: name)

  defp verb("admin.sign_up", name), do: gettext("%{name} signed up", name: name)

  defp verb("admin.report", name), do: gettext("%{name} filed a report", name: name)

  # Still here, because a type added to the schema and not to this list should
  # render as something rather than crash somebody's notifications.
  defp verb(_type, name), do: gettext("Something happened involving %{name}", name: name)

  defp others("reblog", _name, count),
    do: ngettext("%{count} person boosted your post", "%{count} people boosted your post", count)

  defp others("favourite", _name, count),
    do:
      ngettext(
        "%{count} person favourited your post",
        "%{count} people favourited your post",
        count
      )

  defp others("follow", _name, count),
    do: ngettext("%{count} person followed you", "%{count} people followed you", count)

  defp others("mention", _name, count),
    do: ngettext("%{count} person mentioned you", "%{count} people mentioned you", count)

  defp others(_type, name, count),
    do:
      ngettext(
        "%{name} and %{count} other person",
        "%{name} and %{count} other people",
        count - 1,
        name: name
      )

  defp sender_name(request, senders) do
    case senders[request.from_account_id] do
      nil -> gettext("Somebody")
      account -> Account.display_name(account)
    end
  end

  defp stored_types(%{settings: settings}) when is_map(settings) do
    settings |> Map.get("notification_types", []) |> Enum.filter(&(&1 in @offered_types))
  end

  defp stored_types(_user), do: []

  # Kept on the user rather than in the URL: a filter somebody has to set again
  # on every visit is one nobody uses.
  defp remember(socket, types) do
    user = socket.assigns.current_scope.user

    Accounts.update_user_settings(
      user,
      Map.put(user.settings || %{}, "notification_types", types)
    )
  end

  defp scopes do
    [{:all, gettext("All")}, {:mentions, gettext("Mentions")}]
  end

  defp scope_path(:all), do: ~p"/notifications"
  defp scope_path(:mentions), do: ~p"/notifications/mentions"

  defp offered_types, do: @offered_types

  defp type_label("mention"), do: gettext("Mentions")
  defp type_label("reblog"), do: gettext("Boosts")
  defp type_label("follow"), do: gettext("Follows")
  defp type_label("follow_request"), do: gettext("Follow requests")
  defp type_label("favourite"), do: gettext("Favourites")
  defp type_label("poll"), do: gettext("Polls")
  defp type_label("update"), do: gettext("Edits")
  defp type_label("quote"), do: gettext("Quotes")

  # Not "Statuses", which is the API's word for a post and nobody else's. What
  # this filter selects is the bell somebody switched on for a person they
  # follow, so it is named after that rather than after the row.
  defp type_label("status"), do: gettext("Posts from people you watch")
  defp type_label(type), do: type

  # A group key carries characters a DOM id may not, so it is hashed rather
  # than interpolated.
  defp dom_id(key), do: :erlang.phash2(key)
end
