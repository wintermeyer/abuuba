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
  alias Abuuba.Statuses.Formatter
  alias Abuuba.Timelines
  alias Abuuba.Trends
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.Meta
  alias AbuubaWeb.PostActions

  @page_size 20

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Explore"),
       viewer: current_account(socket),
       robots: Meta.noindex()
     )
     |> PostActions.attach(lists: [:posts])}
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
            <a href={"/@" <> person.username} class="font-semibold">{Account.display_name(person)}</a>
            <p class="text-sm text-base-content/60">@{Account.acct(person)}</p>
            <p :if={person.note not in [nil, ""]} class="mt-1 text-sm break-words">
              {Formatter.plain_text(person.note, limit: 160)}
            </p>
          </div>

          <button
            :if={followable?(@viewer, person, @following) and not requested?(person, @requested)}
            type="button"
            phx-click="follow"
            phx-value-account={person.id}
            class="btn btn-sm"
          >
            {gettext("Follow")}
          </button>

          <span :if={requested?(person, @requested)} class="badge badge-ghost">
            {gettext("Requested")}
          </span>
        </li>
      </ul>

      <p :if={empty?(assigns)} class="p-8 text-center text-base-content/60">
        <%= if @open? do %>
          {gettext("Nothing here yet. Come back once people have posted.")}
        <% else %>
          {gettext("This server shows what people are posting to those with an account here.")}
        <% end %>
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
        Relationships.follow_or_request(viewer, target)
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

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Plumbing

  defp load(socket) do
    viewer = socket.assigns.viewer

    socket
    |> assign(
      posts: posts(socket.assigns.tab, viewer),
      tags: tags(socket.assigns.tab, viewer),
      people: people(socket.assigns.tab),
      # For the empty state only. `Abuuba.Timelines` decides what is shown;
      # this decides which of the two silences to explain, because "nothing
      # here yet" is a lie on a server that has posts and is refusing them.
      open?: Settings.public_timelines_readable?(viewer)
    )
    |> assign(
      following: following(socket.assigns.tab, viewer),
      requested: requested(socket.assigns.tab, viewer)
    )
  end

  # Read once for the page rather than once per card: twenty people on screen
  # would otherwise be twenty questions asking the same thing. And only for
  # the people tab, which is the only one with a follow button — the whole
  # follow list is not a thing to fetch for a page of posts.
  defp following(tab, viewer) when tab != :people or is_nil(viewer), do: MapSet.new()
  defp following(_tab, viewer), do: viewer |> Relationships.following_ids() |> MapSet.new()

  defp requested(tab, viewer) when tab != :people or is_nil(viewer), do: MapSet.new()
  defp requested(_tab, viewer), do: viewer |> Relationships.requested_ids() |> MapSet.new()

  # Only the tab being looked at asks the database. Three queries for a page
  # that shows one of them is two queries nobody needed.
  defp posts(:posts, viewer) do
    # Both halves ask the same two questions, because both go through
    # `Abuuba.Timelines`. The trending half used to ask neither.
    trending = Trends.statuses(viewer, limit: @page_size)
    recent = Timelines.public(viewer, %{limit: @page_size})

    dedupe(trending ++ recent)
    |> Entities.statuses(viewer, filter_context: "public")
    |> Enum.reject(&hidden?/1)
  end

  defp posts(_tab, _viewer), do: []

  defp tags(:tags, viewer) do
    dedupe(Trends.tags(viewer, limit: @page_size) ++ Statuses.listable_tags(limit: @page_size))
  end

  defp tags(_tab, _viewer), do: []

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

  # There is no unfollow button on this screen, so there is no cancel either --
  # that lives on the profile. What this owes somebody who pressed Follow on an
  # account that approves its followers is the news that they did, rather than
  # a button that quietly disappears as if the follow had gone through.
  defp requested?(person, requested), do: MapSet.member?(requested, person.id)

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

  defp numeric(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> nil
    end
  end

  defp numeric(value) when is_integer(value), do: {:ok, value}
  defp numeric(_value), do: nil
end
