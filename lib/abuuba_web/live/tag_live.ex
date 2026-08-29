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

  alias Abuuba.Settings
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Tag
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.Meta
  alias AbuubaWeb.PostActions

  # Answered here because the action bar is drawn here.
  @post_actions PostActions.toggles()

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

  defp posts(tag, viewer) do
    if Settings.public_timelines_readable?(viewer), do: tag_posts(tag, viewer), else: []
  end

  defp tag_posts(tag, viewer) do
    tag
    |> Statuses.tag_timeline(limit: @page_size)
    |> Entities.statuses(viewer, filter_context: "public")
    |> Enum.reject(&hidden?/1)
  end

  defp following?(nil, _tag), do: false
  defp following?(_viewer, nil), do: false
  defp following?(viewer, tag), do: Statuses.following_tag?(viewer, tag)

  defp viewer_id(nil), do: nil
  defp viewer_id(viewer), do: to_string(viewer.id)

  # Rendered the way this screen renders the rest of them, then swapped in.
  defp replace_post(socket, status) do
    rendered = Entities.status(status, socket.assigns.viewer)

    update(socket, :posts, &PostActions.swap(&1, rendered))
  end

  defp locale(socket), do: socket.assigns[:locale] || Gettext.get_locale(AbuubaWeb.Gettext)
end
