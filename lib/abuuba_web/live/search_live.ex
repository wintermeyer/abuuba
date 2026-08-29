defmodule AbuubaWeb.SearchLive do
  @moduledoc """
  Finding a person, a tag or a post.

  ## The query lives in the address

  `?q=` and `?type=` rather than socket state, so a search is a link somebody
  can send, a bookmark, and something the back button returns to. The type is
  a filter over the same query rather than a different search, which is why
  every section is counted even when only one is shown.

  ## The operators are on the page

  `from:`, `has:`, `before:` and `after:` are listed under the box, read from
  `Abuuba.Search.operators/0`. An interface that hides what its box can do is one
  where only the people who read the source know the features exist, and a
  hand-written list would drift from the parser the first time either changed.
  """

  use AbuubaWeb, :live_view

  import AbuubaWeb.StatusComponent

  alias Abuuba.Accounts.Account
  alias Abuuba.Search
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.Meta
  alias AbuubaWeb.PostActions

  # Answered here because the action bar is drawn here.
  @post_actions PostActions.toggles()

  @page_size 20
  @types ~w(all accounts hashtags statuses)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Search"),
       viewer: current_account(socket),
       operators: Search.operators(),
       robots: Meta.noindex()
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(query: params |> Map.get("q", "") |> to_string(), type: type(params))
     |> search()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <div class="border-b border-base-300 p-4">
        <form id="search-form" phx-submit="search">
          <label class="block">
            <span class="sr-only">{gettext("Search")}</span>
            <input
              type="search"
              name="q"
              value={@query}
              placeholder={gettext("A name, a #tag, or some words")}
              class="input w-full"
            />
          </label>
          <button type="submit" class="btn btn-primary btn-sm mt-2">{gettext("Search")}</button>
        </form>

        <details class="mt-3">
          <summary class="cursor-pointer text-sm text-base-content/70">
            {gettext("Narrowing a search")}
          </summary>
          <dl class="mt-2 space-y-1 text-sm">
            <div :for={operator <- @operators} class="flex flex-wrap gap-2">
              <dt><code class="rounded bg-base-200 px-1">{operator.example}</code></dt>
              <dd class="text-base-content/70">{operator_hint(operator.name)}</dd>
            </div>
          </dl>
        </details>
      </div>

      <nav
        :if={@query != ""}
        class="flex border-b border-base-300"
        aria-label={gettext("What to show")}
      >
        <.link
          :for={{value, label} <- types()}
          patch={search_path(@query, value)}
          aria-current={@type == value && "page"}
          class={["px-4 py-2", @type == value && "border-b-2 border-primary font-semibold"]}
        >
          {label}
        </.link>
      </nav>

      <section :if={show?(@type, "accounts") and @accounts != []} aria-label={gettext("People")}>
        <h2 class="px-4 pt-3 text-xs uppercase text-base-content/60">{gettext("People")}</h2>
        <ul class="divide-y divide-base-300">
          <li :for={person <- @accounts} class="p-4">
            <a href={"/@" <> Account.acct(person)} class="font-semibold">{Account.display_name(person)}</a>
            <p class="text-sm text-base-content/60">@{Account.acct(person)}</p>
          </li>
        </ul>
      </section>

      <section :if={show?(@type, "hashtags") and @tags != []} aria-label={gettext("Hashtags")}>
        <h2 class="px-4 pt-3 text-xs uppercase text-base-content/60">{gettext("Hashtags")}</h2>
        <ul class="divide-y divide-base-300">
          <li :for={tag <- @tags} class="p-4">
            <a href={"/tags/" <> tag.name} class="font-semibold">#{tag.name}</a>
          </li>
        </ul>
      </section>

      <section :if={show?(@type, "statuses") and @statuses != []} aria-label={gettext("Posts")}>
        <h2 class="px-4 pt-3 text-xs uppercase text-base-content/60">{gettext("Posts")}</h2>
        <.status
          :for={post <- @statuses}
          id={"result-#{post["id"]}"}
          status={post}
          viewer_id={viewer_id(@viewer)}
          interactive={@viewer != nil}
        />
      </section>

      <p :if={@query != "" and nothing?(assigns)} class="p-8 text-center text-base-content/60">
        {gettext("Nothing matched that.")}
      </p>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, push_patch(socket, to: search_path(query, socket.assigns.type))}
  end

  # The action bar is drawn on this screen, so the events it raises are
  # answered here. See `AbuubaWeb.PostActions` for why the work behind them is
  # one module rather than a copy per screen.
  def handle_event(event, %{"id" => id}, socket) when event in @post_actions do
    case PostActions.toggle(socket.assigns.viewer, event, id) do
      {:ok, status} -> {:noreply, replace_post(socket, status)}
      :error -> {:noreply, socket}
    end
  end

  # The poll form is drawn by the same component as the action bar, so it is
  # answered in the same place. See `AbuubaWeb.PostActions`.
  def handle_event("vote", %{"poll_id" => poll_id} = params, socket) do
    choices = params |> Map.get("choices", []) |> List.wrap()

    case PostActions.vote(socket.assigns.viewer, poll_id, choices) do
      {:ok, status} -> {:noreply, replace_post(socket, status)}
      :error -> {:noreply, socket}
    end
  end

  # There is no composer on this screen, so replying goes to the post, which
  # has one. A box that appears on some screens and not others is worse than
  # the same answer everywhere.
  def handle_event("reply", %{"id" => id}, socket) do
    case PostActions.page_of(socket.assigns.viewer, id) do
      nil -> {:noreply, socket}
      path -> {:noreply, push_navigate(socket, to: path)}
    end
  end

  # The pencil is drawn by the same component as the rest of the bar, and the
  # box to edit in is on the post's own page. Same answer as "reply" for the
  # same reason: a composer that appears on some screens and not others is
  # worse than the same answer everywhere.
  def handle_event("edit", %{"id" => id}, socket) do
    case PostActions.page_of(socket.assigns.viewer, id) do
      nil -> {:noreply, socket}
      path -> {:noreply, push_navigate(socket, to: path)}
    end
  end

  # Drawn by the same component as the rest of the bar. A translation is not a
  # change to the post, so it is put straight back into the list rather than
  # re-read. See `AbuubaWeb.PostActions`.
  def handle_event("translate", %{"id" => id}, socket) do
    case PostActions.translate(socket.assigns.viewer, id, locale(socket)) do
      {:ok, rendered} ->
        {:noreply, update(socket, :statuses, &PostActions.swap(&1, rendered))}

      :error ->
        {:noreply, put_flash(socket, :error, gettext("That could not be translated just now."))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Plumbing

  # Only the section being shown asks the database. A deep link to one kind of
  # result should not pay for the other two.
  defp search(%{assigns: %{query: ""}} = socket) do
    assign(socket, accounts: [], tags: [], statuses: [])
  end

  defp search(socket) do
    query = socket.assigns.query
    type = socket.assigns.type
    viewer = socket.assigns.viewer

    # The operators narrow posts and mean nothing to a name or a tag, so those
    # two search the words. Handing them the raw string looks for
    # "from:bob gardening" as a name and silently loses two of the three
    # sections.
    words = Search.parse(query).text

    assign(socket,
      accounts:
        if(show?(type, "accounts"),
          do: Search.accounts(words, viewer, limit: @page_size),
          else: []
        ),
      tags:
        if(show?(type, "hashtags"), do: Search.tags(words, viewer, limit: @page_size), else: []),
      statuses: statuses(type, query, viewer)
    )
  end

  defp statuses(type, query, viewer) do
    if show?(type, "statuses") do
      query
      |> Search.statuses(viewer, limit: @page_size)
      |> Entities.statuses(viewer, filter_context: "public")
      |> Enum.reject(&hidden?/1)
    else
      []
    end
  end

  defp show?("all", _section), do: true
  defp show?(type, section), do: type == section

  defp nothing?(%{accounts: [], tags: [], statuses: []}), do: true
  defp nothing?(_assigns), do: false

  # A type nobody defined is treated as everything rather than as an error: the
  # value came from a URL somebody may have edited or a link that went stale,
  # and showing them the whole answer is better than showing them nothing.
  defp type(params) do
    case Map.get(params, "type") do
      value when value in @types -> value
      _ -> "all"
    end
  end

  defp types do
    [
      {"all", gettext("Everything")},
      {"accounts", gettext("People")},
      {"hashtags", gettext("Hashtags")},
      {"statuses", gettext("Posts")}
    ]
  end

  defp search_path(query, "all"), do: ~p"/search?#{[q: query]}"
  defp search_path(query, type), do: ~p"/search?#{[q: query, type: type]}"

  defp operator_hint("from:"), do: gettext("posts by one person")
  defp operator_hint("has:"), do: gettext("posts carrying a picture or a poll")
  defp operator_hint("before:"), do: gettext("posts older than a date")
  defp operator_hint("after:"), do: gettext("posts newer than a date")
  defp operator_hint(name), do: name

  defp viewer_id(nil), do: nil
  defp viewer_id(viewer), do: to_string(viewer.id)

  # Rendered the way this screen renders the rest of them, then swapped in.
  defp replace_post(socket, status) do
    rendered = Entities.status(status, socket.assigns.viewer)

    update(socket, :statuses, &PostActions.swap(&1, rendered))
  end

  defp locale(socket), do: socket.assigns[:locale] || Gettext.get_locale(AbuubaWeb.Gettext)
end
