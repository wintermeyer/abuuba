defmodule AbuubaWeb.SavedLive do
  @moduledoc """
  The two lists a reader builds by pressing buttons on posts.

  ## Why the pages exist at all

  `AbuubaWeb.StatusComponent` draws a bookmark and a favourite on every post on
  every screen, and `GET /api/v1/bookmarks` and `/api/v1/favourites` have always
  answered them. Nothing in this server's own interface showed either, so a
  reader could file a post away and never find it again -- which is the same
  thing to them as a button that does nothing.

  ## One module, two lists

  They differ in one query and two sentences. Two modules would be two places
  to fix the next thing the action bar learns to do, which is the copy-and-drift
  `AbuubaWeb.PostActions` was written to end.

  ## Acting on a post takes it off the list it is on

  Unbookmarking a post while reading the bookmarks is the reader saying "not
  this one", so it goes. Leaving it there until a reload would read as the
  button not having worked, and putting it back rendered is worse: a list of
  bookmarks with an unbookmarked post on it is a list that is lying.
  """

  use AbuubaWeb, :live_view

  import AbuubaWeb.StatusComponent

  alias Abuuba.Statuses
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.Meta
  alias AbuubaWeb.PostActions

  @page_size 40

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(robots: Meta.noindex(), viewer: current_account(socket))
     |> PostActions.attach(lists: [:posts], remove: &drop/2, put_back: &put_back/2)}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(page_title: title(socket.assigns.live_action)) |> load()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <h1 class="p-4 text-xl font-semibold">{@page_title}</h1>

      <nav class="flex border-b border-base-300" aria-label={gettext("Which list")}>
        <.link
          :for={{action, label} <- tabs()}
          navigate={path(action)}
          aria-current={@live_action == action && "page"}
          class={[
            "px-4 py-2",
            @live_action == action && "border-b-2 border-primary font-semibold"
          ]}
        >
          {label}
        </.link>
      </nav>

      <div id="saved-posts">
        <.status
          :for={post <- @posts}
          id={"saved-#{post["id"]}"}
          status={post}
          viewer_id={viewer_id(@viewer)}
        />
      </div>

      <p :if={@posts == []} class="p-8 text-center text-base-content/60">
        {empty_message(@live_action)}
      </p>
    </Layouts.app>
    """
  end

  defp tabs do
    [{:bookmarks, gettext("Bookmarks")}, {:favourites, gettext("Favourites")}]
  end

  defp path(:bookmarks), do: ~p"/bookmarks"
  defp path(:favourites), do: ~p"/favourites"

  defp title(:bookmarks), do: gettext("Bookmarks")
  defp title(:favourites), do: gettext("Favourites")

  # Named after the button that fills the list rather than after the list, so
  # somebody who arrived here without knowing what a bookmark is on this server
  # finds out.
  defp empty_message(:bookmarks) do
    gettext("Nothing bookmarked yet. The bookmark under a post files it here, and tells nobody.")
  end

  defp empty_message(:favourites) do
    gettext("Nothing favourited yet. The star under a post lands here, and its author is told.")
  end

  # The collections come back as the mark and the post it names, because what a
  # client pages through is the order things were saved in rather than the
  # order they were written. Only the post is drawn.
  defp load(socket) do
    viewer = socket.assigns.viewer

    posts =
      socket.assigns.live_action
      |> collection(viewer)
      |> Enum.map(& &1.status)
      |> Entities.statuses(viewer, filter_context: "home")

    assign(socket, posts: posts)
  end

  defp collection(:bookmarks, viewer), do: Statuses.bookmarks(viewer, %{limit: @page_size})
  defp collection(:favourites, viewer), do: Statuses.favourites(viewer, %{limit: @page_size})

  # A post the reader has just taken off this list, and one they have only
  # redrawn. The action bar cannot know which list it is being pressed on, so
  # the decision is here.
  defp put_back(socket, rendered) do
    if still_listed?(socket.assigns.live_action, rendered) do
      Phoenix.Component.update(socket, :posts, &PostActions.swap(&1, rendered))
    else
      drop(socket, rendered["id"])
    end
  end

  defp drop(socket, id) do
    Phoenix.Component.update(socket, :posts, fn posts ->
      Enum.reject(posts, &PostActions.about?(&1, id))
    end)
  end

  defp still_listed?(:bookmarks, rendered), do: rendered["bookmarked"] == true
  defp still_listed?(:favourites, rendered), do: rendered["favourited"] == true
end
