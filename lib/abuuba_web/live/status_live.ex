defmodule AbuubaWeb.StatusLive do
  @moduledoc """
  One post, with the conversation around it.

  ## Rendered by the server, for everybody

  This is the address the whole fediverse links to, so most arrivals are not
  signed in and many are not people: a link preview, a search crawler, somebody
  clicking through from another server. All of them get the finished HTML from
  the first response, including the tags a preview reads. A page that filled
  itself in after a socket connected would preview as an empty box.

  ## The handle is part of the address

  `/@bob/123` is Bob's post, and asking for `/@carol/123` is not a request for
  the same thing under another name; it is a miss. The alternative invites the
  same post to be linked under any handle anybody likes.

  ## Fetching the rest is asked for, never automatic

  A reply on a server nobody here follows is one this server has never been
  sent. Going and asking is the only way to show it, and it makes this server
  talk to another one on somebody's say-so, so it is a button, and only for
  people who are signed in.
  """

  use AbuubaWeb, :live_view

  import AbuubaWeb.StatusComponent

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.ResolveStatus
  alias Abuuba.Federation.Serializer
  alias Abuuba.Federation.URIs
  alias Abuuba.Statuses
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.ComposeComponent
  alias AbuubaWeb.Meta
  alias AbuubaWeb.PostActions

  @post_actions PostActions.toggles()

  @impl Phoenix.LiveView
  def mount(%{"username" => username, "id" => id}, _session, socket) do
    viewer = current_account(socket)

    with %{} = author <- Accounts.lookup(username),
         false <- blocked?(author, viewer),
         %{} = status <- own_status(author, id, viewer) do
      {:ok, socket |> assign(author: author, status: status, viewer: viewer) |> load_thread()}
    else
      _ -> raise AbuubaWeb.NotFound, "no such post"
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <.live_component
        :if={@viewer}
        module={ComposeComponent}
        id="compose"
        account={@viewer}
        user={@current_scope.user}
      />

      <div id="thread">
        <.status
          :for={post <- @ancestors}
          id={"thread-#{post["id"]}"}
          status={post}
          viewer_id={viewer_id(@viewer)}
          interactive={@viewer != nil}
        />

        <div aria-current="true" class="border-l-4 border-primary">
          <.status
            id={"thread-#{@rendered["id"]}"}
            status={@rendered}
            viewer_id={viewer_id(@viewer)}
            interactive={@viewer != nil}
            menu
          />
        </div>

        <.status
          :for={post <- @descendants}
          id={"thread-#{post["id"]}"}
          status={post}
          viewer_id={viewer_id(@viewer)}
          interactive={@viewer != nil}
        />
      </div>

      <div :if={@viewer && not @status.local} class="p-4 text-center">
        <button type="button" phx-click="fetch_replies" class="btn btn-ghost btn-sm">
          {gettext("Look for more replies on the other server")}
        </button>
      </div>

      <p :if={@fetch_error} class="p-4 text-center text-sm text-error" role="alert">
        {@fetch_error}
      </p>
    </Layouts.app>
    """
  end

  ## Events

  @impl Phoenix.LiveView
  def handle_event("fetch_replies", _params, socket) do
    if socket.assigns.viewer do
      {:noreply, fetch_replies(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("reply", %{"id" => id}, socket) do
    case find(socket, id) do
      nil -> {:noreply, socket}
      status -> {:noreply, open_compose(socket, reply_to: status)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    viewer = socket.assigns.viewer

    case find(socket, id) do
      %{account_id: author_id} = status when not is_nil(viewer) and author_id == viewer.id ->
        {:noreply, open_compose(socket, editing: status)}

      _ ->
        {:noreply, socket}
    end
  end

  # Through `AbuubaWeb.PostActions`, which every screen drawing the action bar
  # uses. The thread is reloaded rather than one post swapped: an action on the
  # post being read changes the counts shown on it and nothing else here.
  def handle_event(event, %{"id" => id}, socket) when event in @post_actions do
    case PostActions.toggle(socket.assigns.viewer, event, id) do
      {:ok, _status} -> {:noreply, load_thread(socket)}
      :error -> {:noreply, socket}
    end
  end

  # The poll form is drawn by the same component as the action bar, so it is
  # answered in the same place. See `AbuubaWeb.PostActions`.
  def handle_event("vote", %{"poll_id" => poll_id} = params, socket) do
    choices = params |> Map.get("choices", []) |> List.wrap()

    case PostActions.vote(socket.assigns.viewer, poll_id, choices) do
      {:ok, _status} -> {:noreply, load_thread(socket)}
      :error -> {:noreply, socket}
    end
  end

  # Muting from the thread view redraws it rather than removing anything: you
  # are reading the conversation you have just silenced, and taking it off the
  # screen under you would be a page that empties itself when you press a
  # button on it.
  def handle_event("mute_thread", %{"id" => id}, socket) do
    thread(socket, id, &Statuses.mute_thread/2)
  end

  def handle_event("unmute_thread", %{"id" => id}, socket) do
    thread(socket, id, &Statuses.unmute_thread/2)
  end

  # The translated text replaces what is rendered, with a line saying who
  # translated it. Showing both at once doubles the length of every post on the
  # page, and a reader who wanted the original can reload.
  # Through `AbuubaWeb.PostActions` like every other screen. The credit travels
  # inside the rendered post now rather than in an assign of this page's own,
  # which is what lets a list screen put a translated post back where it was.
  def handle_event("translate", %{"id" => id}, socket) do
    case PostActions.translate(socket.assigns.viewer, id, locale(socket)) do
      {:ok, rendered} ->
        {:noreply, assign(socket, rendered: rendered)}

      :error ->
        {:noreply, put_flash(socket, :error, gettext("That could not be translated just now."))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp locale(socket), do: socket.assigns[:locale] || Gettext.get_locale(AbuubaWeb.Gettext)

  @impl Phoenix.LiveView
  # The fetcher is injected rather than called directly, so a test can exercise
  # this path without a network and without a live peer.
  def handle_info({:test_fetcher, fetcher}, socket) do
    {:noreply, assign(socket, fetcher: fetcher)}
  end

  def handle_info({:composed, _status}, socket), do: {:noreply, load_thread(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Plumbing

  defp load_thread(socket) do
    viewer = socket.assigns.viewer
    status = socket.assigns.status
    %{ancestors: ancestors, descendants: descendants} = Statuses.context(status, viewer)

    # The whole page — both halves of the thread and the post itself — goes
    # through one rendering batch and is split back apart by position.
    {rendered_ancestors, [rendered | rendered_descendants]} =
      (ancestors ++ [status] ++ descendants)
      |> Entities.statuses(viewer, filter_context: "thread")
      |> Enum.split(length(ancestors))

    socket
    |> assign(
      # The post somebody opened is shown whatever their rules say — folded or
      # dropped — because they asked for this one by following a link to it.
      # Its thread is filtered like any other list.
      ancestors: Enum.reject(rendered_ancestors, &hidden?/1),
      descendants: Enum.reject(rendered_descendants, &hidden?/1),
      rendered: Map.delete(rendered, "filtered"),
      page_title: title(socket.assigns.author, status)
    )
    |> assign_new(:fetcher, fn -> nil end)
    |> assign_new(:fetch_error, fn -> nil end)
    |> put_meta()
  end

  # Set on the socket rather than on the conn, because the root layout reads
  # the LiveView's own assigns on the first, server-rendered response.
  defp put_meta(socket) do
    status = socket.assigns.status
    author = socket.assigns.author
    summary = summary(status)

    socket
    |> assign(:robots, robots(author))
    |> assign(
      :page_meta,
      [
        {"property", "og:type", "article"},
        {"property", "og:title", title(author, status)},
        {"property", "og:description", summary},
        {"property", "og:url", URIs.status_url(author, status.id)},
        {"name", "description", summary}
      ]
    )
    # What an editor fetches before it turns a pasted link into an embed.
    # Without the tag, nothing discovers the endpoint.
    |> assign(:page_links, [
      %{
        rel: "alternate",
        type: "application/json+oembed",
        href:
          "#{URIs.base_url()}/api/oembed?url=" <>
            URI.encode_www_form(URIs.status_url(author, status.id))
      },
      # And the post itself, for a fetcher that was handed this page instead
      # of the object: the way a pasted post address resolves.
      %{
        rel: "alternate",
        type: "application/activity+json",
        href: Serializer.status_uri(status, author)
      }
    ])
  end

  # Off until the author asks to be indexed, matching the profile page: a post
  # that a crawler may keep is a post a crawler may keep whichever page it
  # found it on.
  defp robots(%{indexable: true}), do: nil
  defp robots(_author), do: Meta.noindex()

  defp title(author, status) do
    gettext("%{name} on %{server}",
      name: Account.display_name(author),
      server: Abuuba.Instance.software_name()
    ) <> ": " <> String.slice(summary(status), 0, 60)
  end

  # The warning rather than the words when there is one. A preview that unfolds
  # somebody's content warning defeats the warning.
  #
  # On one line, because a newline inside a meta tag's content is what turns a
  # tidy preview into a broken one.
  defp summary(%{spoiler_text: text}) when is_binary(text) and text != "", do: one_line(text)
  defp summary(%{text: text}), do: text |> one_line() |> String.slice(0, 200)

  defp one_line(text) do
    text |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()
  end

  # Under this author, and visible to whoever is asking. Both checks are the
  # query's rather than an afterthought: one that cannot return the wrong row
  # cannot leak one.
  defp own_status(author, id, viewer) do
    with {number, ""} <- Integer.parse(to_string(id)),
         %{account_id: account_id} = status when account_id == author.id <-
           Statuses.get_status(number, viewer) do
      status
    else
      _ -> nil
    end
  end

  defp fetch_replies(socket) do
    status = socket.assigns.status
    fetcher = socket.assigns.fetcher || (&ResolveStatus.resolve_thread/1)

    case fetcher.(status.uri) do
      {:ok, _resolved} ->
        socket |> assign(fetch_error: nil) |> load_thread()

      _error ->
        assign(socket,
          fetch_error: gettext("That server could not be reached, so this is all there is.")
        )
    end
  end

  defp thread(socket, id, fun) do
    with %{} = viewer <- socket.assigns.viewer,
         status when not is_nil(status) <- find(socket, id) do
      fun.(viewer, status)
    end

    {:noreply, load_thread(socket)}
  end

  defp find(socket, id) do
    case Integer.parse(to_string(id)) do
      {number, ""} -> Statuses.get_status(number, socket.assigns.viewer)
      _ -> nil
    end
  end

  defp open_compose(socket, context) do
    send_update(ComposeComponent, [id: "compose"] ++ context)

    socket
  end

  # Somebody who blocked you is not showing you their posts, and the page is
  # the one place where a direct link would otherwise walk around that.
  defp blocked?(_author, nil), do: false
  defp blocked?(author, viewer), do: Abuuba.Relationships.blocking?(author, viewer)

  defp viewer_id(nil), do: nil
  defp viewer_id(viewer), do: to_string(viewer.id)
end
