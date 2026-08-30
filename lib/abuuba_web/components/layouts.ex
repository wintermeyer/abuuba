defmodule AbuubaWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AbuubaWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :page_title, :string, default: nil, doc: "what this page is, for the heading and the tab"

  slot :inner_block, required: true
  slot :aside, doc: "the third column on a wide screen; folded below the content on a narrow one"

  def app(assigns) do
    ~H"""
    <a
      href="#main"
      class="sr-only focus:not-sr-only focus:absolute focus:z-50 focus:m-2 focus:rounded focus:bg-base-100 focus:px-4 focus:py-2 focus:ring-2"
    >
      {gettext("Skip to content")}
    </a>

    <div class="min-h-screen lg:grid lg:grid-cols-[16rem_1fr] xl:grid-cols-[16rem_minmax(0,42rem)_1fr]">
      <%!-- Built here rather than in the function body above, so that change
      tracking can skip it. The list carries the unread badge, which costs a
      query: computed in the body it would be rebuilt on every render, and a
      live timeline renders on every arriving post. As an attribute it is
      rebuilt only when `@current_scope` actually changes, which is where the
      badge can have moved. --%>
      <.side_nav items={nav_items(@current_scope)} signed_in={@current_scope[:user] != nil} />

      <main id="main" tabindex="-1" class="min-w-0 border-base-300 lg:border-x">
        <h1 :if={@page_title} class="sr-only">{@page_title}</h1>
        {render_slot(@inner_block)}
      </main>

      <aside :if={@aside != []} class="hidden xl:block p-4">
        {render_slot(@aside)}
      </aside>
    </div>

    <.mobile_nav items={nav_items(@current_scope)} />
    <.live_region />
    <.flash_group flash={@flash} />
    <.dev_mailbox />
    """
  end

  @doc """
  A way to the development mailbox, from wherever you are.

  Everything this server sends in development goes to a preview box rather than
  to anybody, and finding it meant remembering the address. The moment you want
  it is the moment you have just been told to check your email, which is a
  moment you are usually in the middle of something else.

  Renders nothing outside development, where the route it points at is not
  mounted: a link that answers 404 would be worse than no link at all.
  """
  attr :inline, :boolean,
    default: false,
    doc: "a sentence in the page rather than the corner, for a screen that has just sent mail"

  def dev_mailbox(assigns) do
    assigns = assign(assigns, :shown?, dev_routes?())

    ~H"""
    <p :if={@shown? and @inline} class="mt-2 text-sm text-base-content/60">
      This server is in development, so nothing was actually sent.
      <a href="/dev/mailbox" class="underline">Open the mailbox</a>
      to read it.
    </p>

    <a
      :if={@shown? and not @inline}
      href="/dev/mailbox"
      class="fixed bottom-20 right-3 z-40 rounded bg-base-300 px-3 py-1 text-sm opacity-70 hover:opacity-100 lg:bottom-3"
      title="Everything this server would have emailed"
    >
      Mailbox
    </a>
    """
  end

  # The same flag the router gates `/dev/mailbox` on, so the link exists
  # exactly where the thing it points at does. Read at runtime rather than
  # compiled in, because a component that can only be built one way can only be
  # tested one way, and "renders nothing in production" is the half worth a
  # test. The address is a literal string for the same reason: a verified route
  # would not compile in a build where it is not mounted.
  defp dev_routes?, do: Application.get_env(:abuuba, :dev_routes, false)

  @doc """
  The navigation that is a sidebar on a wide screen and a bar at the bottom on a
  narrow one.

  At the bottom rather than the top on a phone, because that is where a thumb
  reaches. The same links in both, so that somebody describing the interface to
  somebody else is describing one interface.
  """
  attr :items, :list, required: true
  attr :signed_in, :boolean, default: false, doc: "whether there is a session to end"

  def side_nav(assigns) do
    ~H"""
    <nav
      class="hidden lg:flex lg:flex-col lg:gap-1 lg:p-4 lg:sticky lg:top-0 lg:h-screen"
      aria-label={gettext("Main")}
    >
      <a href={~p"/"} class="mb-4 flex items-center gap-2 px-3 py-2 font-semibold">
        <img src={~p"/images/logo.svg"} width="28" alt="" />
        <span>{Abuuba.Instance.software_name()}</span>
      </a>

      <.nav_link :for={item <- @items} item={item} />

      <div class="mt-auto flex flex-col gap-1 px-3 py-2 text-sm">
        <%!-- Below the six rather than among them: the list above is also the
        bar along the bottom of a phone, and these two are the reader's own
        filing rather than a place they go. A narrow screen reaches them from
        the settings overview. --%>
        <.link :if={@signed_in} navigate={~p"/bookmarks"} class="link link-hover">
          {gettext("Bookmarks")}
        </.link>
        <.link :if={@signed_in} navigate={~p"/favourites"} class="link link-hover">
          {gettext("Favourites")}
        </.link>
        <a href={~p"/shortcuts"} class="link link-hover">{gettext("Keyboard shortcuts")}</a>
        <.link :if={@signed_in} href={~p"/logout"} method="delete" class="link link-hover">
          {gettext("Sign out")}
        </.link>
      </div>
    </nav>
    """
  end

  attr :items, :list, required: true

  def mobile_nav(assigns) do
    ~H"""
    <nav
      class="fixed inset-x-0 bottom-0 z-40 flex justify-around border-t border-base-300 bg-base-100 lg:hidden"
      aria-label={gettext("Main")}
    >
      <a
        :for={item <- @items}
        href={item.path}
        class="flex flex-1 flex-col items-center gap-1 px-2 py-3 text-xs"
      >
        <span class={[item.icon, "size-5"]} aria-hidden="true" /> {item.label}
      </a>
    </nav>
    """
  end

  attr :item, :map, required: true

  defp nav_link(assigns) do
    ~H"""
    <a
      href={@item.path}
      class="flex items-center gap-3 rounded px-3 py-2 hover:bg-base-200 focus-visible:ring-2"
    >
      <span class={[@item.icon, "size-5"]} aria-hidden="true" /> {@item.label}
      <%!-- The id is per item. It was a constant while notifications were the
      only counted link, and a second one would have put two elements with the
      same id on every page -- which is invalid HTML and, worse here, the key
      LiveView patches the DOM by. --%>
      <span
        :if={@item[:badge] && @item.badge > 0}
        id={badge_id(@item)}
        class="badge badge-primary badge-sm ml-auto"
      >
        {@item.badge}
        <span class="sr-only">{gettext("unread")}</span>
      </span>
    </a>
    """
  end

  defp badge_id(%{path: path}), do: "badge-" <> String.replace(path, ~r|[^a-zA-Z0-9]+|, "-")

  @doc """
  The region screen readers announce changes through.

  One per page, empty, and written into by anything that changes the page
  without a navigation. Without it a reader who cannot see the screen is told
  nothing when a post is sent or a timeline grows, and the interface simply
  looks broken to them.
  """
  def live_region(assigns \\ %{}) do
    ~H"""
    <div id="live-region" class="sr-only" role="status" aria-live="polite" aria-atomic="true"></div>
    """
  end

  # Counted in the navigation rather than only on the notifications page: a
  # count that appears once you are already looking at the column is a count
  # nobody needed. One query per page for a signed-in reader, which is what the
  # cap inside `unread_badge/1` keeps cheap.
  defp unread_notifications(%{account_id: account_id}) when not is_nil(account_id) do
    Abuuba.Notifications.unread_badge(account_id)
  end

  defp unread_notifications(_user), do: 0

  # Counted next to the link for the same reason: a message waiting in a place
  # nobody is looking at is a message that has not arrived.
  defp unread_conversations(%{account_id: account_id}) when not is_nil(account_id) do
    Abuuba.Conversations.unread_count(account_id)
  end

  defp unread_conversations(_user), do: 0

  # Drawn only while somebody is waiting, which is how the reference
  # implementation does it and is the only way it earns a place in a
  # navigation this short: on a server where nobody approves their followers
  # a permanent entry is a permanent reminder of nothing. It is also the one
  # entry that has to be here rather than in the settings, because a request
  # is somebody waiting on an answer.
  defp follow_requests(%{account_id: account_id}) when not is_nil(account_id) do
    Abuuba.Relationships.pending_follower_count(account_id)
  end

  defp follow_requests(_user), do: 0

  # Signed out, the only useful destinations are the public ones. Showing a
  # "Home" that answers 422 would be an interface arguing with itself.
  defp nav_items(%{user: user}) when not is_nil(user) do
    waiting = follow_requests(user)

    [
      %{path: ~p"/home", label: gettext("Home"), icon: "hero-home"},
      %{
        path: ~p"/notifications",
        label: gettext("Notifications"),
        icon: "hero-bell",
        badge: unread_notifications(user)
      },
      %{
        path: ~p"/conversations",
        label: gettext("Messages"),
        icon: "hero-envelope",
        badge: unread_conversations(user)
      },
      %{path: ~p"/explore", label: gettext("Explore"), icon: "hero-hashtag"},
      %{path: ~p"/search", label: gettext("Search"), icon: "hero-magnifying-glass"},
      %{path: ~p"/settings", label: gettext("Settings"), icon: "hero-cog-6-tooth"}
    ] ++ waiting_item(waiting)
  end

  defp nav_items(_scope) do
    [
      %{path: ~p"/", label: gettext("Home"), icon: "hero-home"},
      %{path: ~p"/explore", label: gettext("Explore"), icon: "hero-hashtag"},
      %{path: ~p"/search", label: gettext("Search"), icon: "hero-magnifying-glass"},
      %{path: ~p"/login", label: gettext("Log in"), icon: "hero-arrow-right-on-rectangle"}
    ]
  end

  defp waiting_item(0), do: []

  defp waiting_item(count) do
    [
      %{
        path: ~p"/follow-requests",
        label: gettext("Follow requests"),
        icon: "hero-user-plus",
        badge: count
      }
    ]
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
