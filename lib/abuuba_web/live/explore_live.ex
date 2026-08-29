defmodule AbuubaWeb.ExploreLive do
  @moduledoc """
  Where somebody who follows nobody yet finds something.

  ## Three tabs, three addresses

  Posts, hashtags and people, each its own route, so each is a link somebody
  can send and a crawler can index. Public throughout: this is the page a
  stranger lands on, and asking them to sign in before showing them anything is
  asking them to trust a server they have not seen.

  ## Trending first, then everything else

  Whatever is trending and has been allowed through the review queue comes
  first, and the rest of the tab follows in recency order behind it. On a quiet
  server, or before anybody has reviewed anything, the trending part is empty
  and the page is exactly the recency list it used to be. That is honest either
  way: nothing is labelled as trending unless it is.

  ## Being listed is a choice

  The directory shows local accounts that asked to be discoverable, and the
  default is no. Somebody who never opened a settings page has not agreed to be
  on a public list of the people who live here.
  """

  use AbuubaWeb, :live_view

  import AbuubaWeb.StatusComponent

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Relationships
  alias Abuuba.Settings
  alias Abuuba.Statuses
  alias Abuuba.Trends
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.Meta
  alias AbuubaWeb.PostActions

  # Answered here because the action bar is drawn here.
  @post_actions PostActions.toggles()

  @page_size 20

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Explore"),
       viewer: current_account(socket),
       robots: Meta.noindex()
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(tab: socket.assigns.live_action) |> load()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <nav class="flex border-b border-base-300" aria-label={gettext("What to explore")}>
        <.link
          :for={{action, label} <- tabs()}
          navigate={tab_path(action)}
          aria-current={@tab == action && "page"}
          class={["px-4 py-2", @tab == action && "border-b-2 border-primary font-semibold"]}
        >
          {label}
        </.link>
      </nav>

      <p class="border-b border-base-300 px-4 py-2 text-sm text-base-content/60">
        {gettext("What more people than usual are posting about, then everything else, newest first.")}
      </p>

      <div :if={@tab == :posts}>
        <.status
          :for={post <- @posts}
          id={"explore-#{post["id"]}"}
          status={post}
          viewer_id={viewer_id(@viewer)}
          interactive={@viewer != nil}
        />
      </div>

      <ul :if={@tab == :tags} class="divide-y divide-base-300">
        <li :for={tag <- @tags} class="p-4">
          <a href={tag_path(tag)} class="font-semibold">#{tag.name}</a>
        </li>
      </ul>

      <ul :if={@tab == :people} class="divide-y divide-base-300">
        <li :for={person <- @people} class="flex items-center gap-3 p-4">
          <div class="min-w-0 flex-1">
            <a href={"/@" <> person.username} class="font-semibold">{display_name(person)}</a>
            <p class="text-sm text-base-content/60">@{Account.acct(person)}</p>
            <p :if={person.note not in [nil, ""]} class="mt-1 text-sm break-words">
              {summary(person.note)}
            </p>
          </div>

          <button
            :if={followable?(@viewer, person, @following)}
            type="button"
            phx-click="follow"
            phx-value-account={person.id}
            class="btn btn-sm"
          >
            {gettext("Follow")}
          </button>
        </li>
      </ul>

      <p :if={empty?(assigns)} class="p-8 text-center text-base-content/60">
        {gettext("Nothing here yet. Come back once people have posted.")}
      </p>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("follow", %{"account" => id}, socket) do
    viewer = socket.assigns.viewer

    result =
      with %Account{} <- viewer,
           {:ok, id} <- numeric(id),
           %Account{} = target <- Accounts.get_account(id),
           true <- followable?(viewer, target, socket.assigns.following),
           # The same daily allowance the profile button and the API spend.
           # A screen that suggests people to follow is the easiest place to
           # build a list from, so it is the last place to leave uncounted.
           :ok <- Relationships.take_follow_budget(viewer) do
        Relationships.follow(viewer, target)
      end

    socket =
      case result do
        {:error, :rate_limited} ->
          put_flash(socket, :error, gettext("Too many follows today. Try again tomorrow."))

        _ ->
          socket
      end

    {:noreply, load(socket)}
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
        {:noreply, update(socket, :posts, &PostActions.swap(&1, rendered))}

      :error ->
        {:noreply, put_flash(socket, :error, gettext("That could not be translated just now."))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Plumbing

  defp load(socket) do
    viewer = socket.assigns.viewer

    socket
    |> assign(
      posts: posts(socket.assigns.tab, viewer),
      tags: tags(socket.assigns.tab),
      people: people(socket.assigns.tab)
    )
    |> assign(following: following(socket.assigns.tab, viewer))
  end

  # Read once for the page rather than once per card: twenty people on screen
  # would otherwise be twenty questions asking the same thing. And only for
  # the people tab, which is the only one with a follow button — the whole
  # follow list is not a thing to fetch for a page of posts.
  defp following(tab, viewer) when tab != :people or is_nil(viewer), do: MapSet.new()
  defp following(_tab, viewer), do: viewer |> Relationships.following_ids() |> MapSet.new()

  # Only the tab being looked at asks the database. Three queries for a page
  # that shows one of them is two queries nobody needed.
  defp posts(:posts, viewer) do
    trending =
      "status"
      |> Trends.list(limit: @page_size)
      |> Enum.map(& &1.subject)
      |> Statuses.get_statuses()

    recent = if readable?(viewer), do: Statuses.public_timeline(limit: @page_size), else: []

    dedupe(trending ++ recent)
    |> Entities.statuses(viewer, filter_context: "public")
    |> Enum.reject(&hidden?/1)
  end

  defp posts(_tab, _viewer), do: []

  # The same rule the API enforces. A server whose admin keeps its timelines
  # for people with an account here has to keep them on its own pages too, or
  # the setting says one thing and the front door does another.
  defp readable?(viewer), do: Settings.public_timelines_readable?(viewer)

  defp tags(:tags) do
    trending =
      "tag" |> Trends.list(limit: @page_size) |> Enum.map(& &1.subject) |> Statuses.get_tags()

    dedupe(trending ++ Statuses.listable_tags(limit: @page_size))
  end

  defp tags(_tab), do: []

  # Trending first, the rest behind it, nothing twice.
  defp dedupe(records), do: Enum.uniq_by(records, & &1.id)

  # Newest first, spelled out: the API's default ordering follows the
  # reference implementation (most active first), and this page keeps the
  # documented design of its own -- newest arrivals first. Changing that is a
  # product decision, not a side effect.
  defp people(:people), do: Accounts.directory(limit: @page_size, order: "new")
  defp people(_tab), do: []

  defp empty?(%{tab: :posts, posts: []}), do: true
  defp empty?(%{tab: :tags, tags: []}), do: true
  defp empty?(%{tab: :people, people: []}), do: true
  defp empty?(_assigns), do: false

  # Not yourself, and not somebody you already follow. A button that does
  # nothing is worse than no button.
  defp followable?(nil, _person, _following), do: false

  defp followable?(viewer, person, following) do
    viewer.id != person.id and not MapSet.member?(following, person.id)
  end

  defp tabs do
    [
      {:posts, gettext("Posts")},
      {:tags, gettext("Hashtags")},
      {:people, gettext("People")}
    ]
  end

  defp tab_path(:posts), do: ~p"/explore"
  defp tab_path(:tags), do: ~p"/explore/tags"
  defp tab_path(:people), do: ~p"/explore/people"

  # The same address a hashtag inside a post links to, so the two cannot point
  # at different places.
  defp tag_path(tag), do: "/tags/#{tag.name}"

  defp summary(note) do
    note
    |> to_string()
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 160)
  end

  defp display_name(%Account{display_name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%Account{username: username}), do: username

  defp viewer_id(nil), do: nil
  defp viewer_id(viewer), do: to_string(viewer.id)

  defp numeric(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> nil
    end
  end

  defp numeric(value) when is_integer(value), do: {:ok, value}
  defp numeric(_value), do: nil

  # Rendered the way this screen renders the rest of them, then swapped in.
  defp replace_post(socket, status) do
    rendered = Entities.status(status, socket.assigns.viewer)

    update(socket, :posts, &PostActions.swap(&1, rendered))
  end

  defp locale(socket), do: socket.assigns[:locale] || Gettext.get_locale(AbuubaWeb.Gettext)
end
