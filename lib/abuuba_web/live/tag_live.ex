defmodule AbuubaWeb.TagLive do
  @moduledoc """
  Everything filed under one hashtag.

  ## A tag nobody has used is still a page

  Every hashtag inside every post is a link to this address, including ones
  nobody else has ever written. A 404 here would read as a broken post rather
  than as an empty tag, so an unused tag renders as itself with nothing under
  it.

  ## The name is casefolded

  `#Gardening` and `#gardening` are one tag, which is what a person writing
  either of them means, so the address is normalised before the lookup rather
  than after.
  """

  use AbuubaWeb, :live_view

  import AbuubaWeb.StatusComponent

  alias Abuuba.Statuses
  alias Abuuba.Statuses.Tag
  alias Abuuba.Timelines
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.Meta
  alias AbuubaWeb.PostActions

  @page_size 20

  @impl Phoenix.LiveView
  def mount(%{"name" => name}, _session, socket) do
    normalised = Tag.normalise(name)

    {:ok,
     socket
     |> assign(
       page_title: "#" <> normalised,
       robots: Meta.noindex(),
       name: normalised,
       viewer: current_account(socket),
       tag: Statuses.get_tag(normalised)
     )
     |> PostActions.attach(lists: [:posts])
     |> load()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <header class="flex items-center gap-3 border-b border-base-300 p-4">
        <h1 class="flex-1 text-2xl font-semibold">#{@name}</h1>

        <button
          :if={@tag && @viewer}
          type="button"
          phx-click={if @following?, do: "unfollow_tag", else: "follow_tag"}
          class={["btn btn-sm", !@following? && "btn-primary"]}
        >
          {if @following?, do: gettext("Unfollow"), else: gettext("Follow")}
        </button>
      </header>

      <div id="tag-posts">
        <.status
          :for={post <- @posts}
          id={"tag-#{post["id"]}"}
          status={post}
          viewer_id={viewer_id(@viewer)}
          interactive={@viewer != nil}
        />
      </div>

      <p :if={@posts == []} class="p-8 text-center text-base-content/60">
        {gettext("Nobody has posted under this tag yet.")}
      </p>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("follow_tag", _params, socket) do
    with %{} = viewer <- socket.assigns.viewer, %Tag{} = tag <- socket.assigns.tag do
      Statuses.follow_tag(viewer, tag)
    end

    {:noreply, assign_following(socket)}
  end

  def handle_event("unfollow_tag", _params, socket) do
    with %{} = viewer <- socket.assigns.viewer, %Tag{} = tag <- socket.assigns.tag do
      Statuses.unfollow_tag(viewer, tag)
    end

    {:noreply, assign_following(socket)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load(socket) do
    viewer = socket.assigns.viewer

    assign(socket,
      posts: posts(socket.assigns.tag, viewer),
      following?: following?(viewer, socket.assigns.tag)
    )
  end

  # Following a tag changes the button and nothing else on the page, so the
  # timeline is left where it is. Re-read rather than assumed because the
  # follow above is inside a `with` that can decline to do anything.
  defp assign_following(socket) do
    assign(socket, following?: following?(socket.assigns.viewer, socket.assigns.tag))
  end

  defp posts(nil, _viewer), do: []

  # Through `Timelines.tag/3`, which is what the API answers this question
  # with, and which answers `timeline_access` itself. `Statuses.tag_timeline/2`
  # is the bare query and is never told who is reading, so this page showed a
  # reader the posts of people they had blocked or muted -- hidden everywhere
  # else, and sitting here.
  defp posts(tag, viewer) do
    tag.name
    |> Timelines.tag(viewer, %{limit: @page_size})
    |> Entities.statuses(viewer, filter_context: "public")
    |> Enum.reject(&hidden?/1)
  end

  defp following?(nil, _tag), do: false
  defp following?(_viewer, nil), do: false
  defp following?(viewer, tag), do: Statuses.following_tag?(viewer, tag)
end
