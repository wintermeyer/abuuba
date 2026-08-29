defmodule AbuubaWeb.HomeLive do
  @moduledoc """
  The home timeline.

  ## Streams rather than a list in assigns

  A timeline grows without bound and a socket that held every post in its
  assigns would hold them in memory for as long as the tab is open, on the
  server, per reader. `stream/3` keeps the DOM and forgets the data, which is
  the whole reason LiveView can do this without a client-side framework.

  ## New posts wait rather than jump

  A post arriving while somebody is reading pushes what they were reading down
  the screen, and on a busy timeline it does so every few seconds. So an
  arriving post becomes a count at the top and goes in when the reader asks,
  unless they are already at the top, where inserting it is what they expect.

  ## Optimistic actions

  A favourite updates the button before the server answers, because the round
  trip is long enough to feel like the click did nothing. The server's answer
  replaces it either way, so a refusal corrects the display rather than being
  hidden by it.
  """

  use AbuubaWeb, :live_view

  import AbuubaWeb.StatusComponent

  alias Abuuba.Filters
  alias Abuuba.Statuses
  alias Abuuba.Streaming
  alias Abuuba.Timelines
  alias Abuuba.Timelines.Broadcast
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.ComposeComponent
  alias AbuubaWeb.Params
  alias AbuubaWeb.PostActions

  @post_actions PostActions.toggles()

  @page_size 20

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    account = current_account(socket)
    statuses = Timelines.home(account, %{limit: @page_size})

    if connected?(socket), do: Streaming.subscribe(Streaming.account_topic(account))

    {:ok,
     socket
     |> assign(
       page_title: gettext("Home"),
       account: account,
       pending: [],
       at_top: true,
       oldest: oldest_id(statuses),
       newest: newest_id(statuses),
       done: length(statuses) < @page_size
     )
     # The entity's id is a string key, so the DOM id is derived explicitly
     # rather than by the default that expects a struct.
     |> stream(:statuses, render_all(statuses, account), dom_id: &"statuses-#{&1["id"]}")}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <.live_component
        module={ComposeComponent}
        id="compose"
        account={@account}
        user={@current_scope.user}
      />

      <div class="sticky top-0 z-10 border-b border-base-300 bg-base-100/90 backdrop-blur">
        <button
          :if={@pending != []}
          type="button"
          phx-click="show_pending"
          class="btn btn-block btn-ghost btn-sm"
        >
          {ngettext("%{count} new post", "%{count} new posts", length(@pending))}
        </button>
      </div>

      <div id="timeline" phx-update="stream" phx-viewport-bottom={!@done && "load_older"}>
        <.status
          :for={{dom_id, status} <- @streams.statuses}
          id={dom_id}
          status={status}
          viewer_id={to_string(@account.id)}
          menu
        />
      </div>

      <p :if={@done} class="p-8 text-center text-base-content/60">
        {gettext("You have reached the end.")}
      </p>

      <p :if={@streams.statuses.inserts == [] and @oldest == nil} class="p-8 text-center">
        {gettext("Follow some people and their posts will appear here.")}
      </p>
    </Layouts.app>
    """
  end

  ## Arrivals

  # The reader's own rules against a post arriving live.
  #
  # `Broadcast.render/2` answers from a cache shared by everybody watching, so
  # it cannot carry them: which rules matched is the reader's own answer and
  # not the post's.
  #
  # Read from the database rather than from an assign loaded at mount, because
  # that is what the page render does, and two sets in one session means the
  # page contradicting itself: a rule added after mount folded the post
  # somebody favourited and not the one that arrived a second later.
  defp filtered(socket, status) do
    account = socket.assigns.account

    # Asked before the keyword filters, because this is the reader saying they
    # do not want the person at all rather than not wanting a word. A post
    # arriving here has come straight over the socket to everybody who follows
    # the author, and a mute deliberately leaves that follow in place -- so a
    # muted account went on appearing while somebody watched and vanished the
    # moment they reloaded.
    if Statuses.hidden_for?(status, account) do
      :hide
    else
      keyword_filtered(status, account)
    end
  end

  defp keyword_filtered(status, account) do
    case Filters.match(Filters.all(account), status, "home") do
      [] ->
        Broadcast.render(status, account)

      matched ->
        # `filter_action` is a string column. Compared against `:hide` this
        # branch was never taken, so every post a hide rule matched arrived in
        # full — the rule worked on reload and not while somebody watched.
        if Enum.any?(matched, &(&1.filter_action == "hide")) do
          :hide
        else
          status
          |> Broadcast.render(account)
          |> Map.put("filtered", Enum.map(matched, &Entities.filter_result/1))
        end
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:streaming, "update", status}, socket) do
    account = socket.assigns.account

    # Their own post, or the reader is already at the top: putting it in is what
    # they expect and nothing they were reading moves.
    socket = assign(socket, newest: max(status.id, socket.assigns.newest || 0))

    # Matched once, here, whether the post is going in now or waiting. A post
    # the reader asked to hide must not reach the counter either: "1 new post"
    # about something they said they never wanted to hear of is the existence
    # of it, told.
    case filtered(socket, status) do
      :hide ->
        {:noreply, socket}

      rendered ->
        # Their own post, or the reader is already at the top: putting it in is
        # what they expect and nothing they were reading moves.
        if status.account_id == account.id or socket.assigns.at_top do
          {:noreply, stream_insert(socket, :statuses, rendered, at: 0)}
        else
          {:noreply, update(socket, :pending, &[{status.id, rendered} | &1])}
        end
    end
  end

  def handle_info({:streaming, "delete", status}, socket) do
    {:noreply, stream_delete_by_dom_id(socket, :statuses, "statuses-#{status.id}")}
  end

  # An edit is not announced on the streaming topic, so the row is redrawn from
  # what was saved. A new post arrives on that topic as well and lands in the
  # same place, which makes writing it twice harmless.
  # The timer lives here because a component cannot hold one: `send_after/3`
  # from inside one delivers to this process, so this is where it lands and
  # where it is handed back.
  def handle_info({:compose_autosave, id}, socket) do
    send_update(ComposeComponent, id: id, autosave: true)

    {:noreply, socket}
  end

  # A scheduled post is not on any timeline yet, so there is nothing to insert.
  def handle_info({:composed, :scheduled}, socket) do
    {:noreply, put_flash(socket, :info, gettext("That post is scheduled."))}
  end

  def handle_info({:composed, status}, socket) do
    account = socket.assigns.account

    case Statuses.get_status(status.id, account) do
      nil ->
        {:noreply, socket}

      fresh ->
        {:noreply, insert_one(socket, fresh, at: 0)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Events

  @impl Phoenix.LiveView
  def handle_event("show_pending", _params, socket) do
    socket =
      socket.assigns.pending
      |> Enum.sort_by(fn {id, _rendered} -> id end)
      |> Enum.reduce(socket, fn {_id, rendered}, acc ->
        # Already matched against the reader's rules when it arrived, so this
        # inserts what was waiting rather than rendering it a second time and
        # skipping the filtering on the way.
        stream_insert(acc, :statuses, rendered, at: 0)
      end)

    {:noreply, assign(socket, pending: [], at_top: true)}
  end

  def handle_event("load_older", _params, socket) do
    account = socket.assigns.account

    older =
      Timelines.home(account, %{limit: @page_size, max_id: socket.assigns.oldest})

    socket =
      older
      |> render_all(account)
      |> Enum.reduce(socket, fn rendered, acc ->
        stream_insert(acc, :statuses, rendered, at: -1)
      end)

    {:noreply,
     assign(socket,
       oldest: oldest_id(older) || socket.assigns.oldest,
       done: length(older) < @page_size
     )}
  end

  # The three toggles go through `AbuubaWeb.PostActions`, which is also what the
  # screens without a composer use. Two copies of this is how they came to
  # disagree, and one of the copies did not exist at all.
  def handle_event(event, %{"id" => id}, socket) when event in @post_actions do
    case PostActions.toggle(socket.assigns.account, event, id) do
      {:ok, status} -> {:noreply, insert_one(socket, status)}
      :error -> {:noreply, socket}
    end
  end

  # A muted thread leaves the timeline, so the post the menu was opened from is
  # removed rather than redrawn. Redrawing it would leave the thing you just
  # silenced sitting there until a reload, which reads as the button not
  # having worked.
  def handle_event("mute_thread", %{"id" => id}, socket) do
    with account when not is_nil(account) <- socket.assigns.account,
         status when not is_nil(status) <- Statuses.get_status(Params.to_integer(id), account),
         {:ok, _mute} <- Statuses.mute_thread(account, status) do
      {:noreply, stream_delete(socket, :statuses, %{"id" => to_string(status.id)})}
    else
      _otherwise -> {:noreply, socket}
    end
  end

  def handle_event("unmute_thread", %{"id" => id}, socket) do
    account = socket.assigns.account

    case Statuses.get_status(Params.to_integer(id), account) do
      nil ->
        {:noreply, socket}

      status ->
        Statuses.unmute_thread(account, status)

        {:noreply, insert_one(socket, Statuses.get_status(status.id, account))}
    end
  end

  # Through `AbuubaWeb.PostActions` like the action bar, because the poll form is
  # drawn by the same component on every screen that shows a post.
  def handle_event("vote", %{"poll_id" => poll_id} = params, socket) do
    choices = params |> Map.get("choices", []) |> List.wrap()

    case PostActions.vote(socket.assigns.account, poll_id, choices) do
      {:ok, status} ->
        {:noreply, insert_one(socket, status)}

      :error ->
        {:noreply, put_flash(socket, :error, gettext("That vote could not be counted."))}
    end
  end

  def handle_event("reply", %{"id" => id}, socket) do
    case Statuses.get_status(Params.to_integer(id), socket.assigns.account) do
      nil -> {:noreply, socket}
      status -> {:noreply, open_compose(socket, reply_to: status)}
    end
  end

  # Only the author's own, checked here rather than only in the markup: the
  # button not being drawn is not the same as the event being refused.
  def handle_event("edit", %{"id" => id}, socket) do
    account = socket.assigns.account

    case Statuses.get_status(Params.to_integer(id), account) do
      %{account_id: author_id} = status when author_id == account.id ->
        {:noreply, open_compose(socket, editing: status)}

      _ ->
        {:noreply, socket}
    end
  end

  # Same shared path as everywhere else; a stream takes the rendered post
  # directly, so the translated words go straight back in place.
  def handle_event("translate", %{"id" => id}, socket) do
    case PostActions.translate(socket.assigns.account, id, PostActions.locale(socket)) do
      {:ok, rendered} ->
        {:noreply, stream_insert(socket, :statuses, rendered)}

      :error ->
        {:noreply, put_flash(socket, :error, gettext("That could not be translated just now."))}
    end
  end

  def handle_event("mark_read", %{"id" => id}, socket) do
    # Where the reader had got to, so the next device starts there rather than
    # at the top with no idea what this one already saw.
    Timelines.put_marker(socket.assigns.account, "home", Params.to_integer(id))

    {:noreply, socket}
  end

  def handle_event("at_top", %{"value" => value}, socket) do
    {:noreply, assign(socket, at_top: value == true)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Plumbing

  defp open_compose(socket, context) do
    send_update(ComposeComponent, [id: "compose"] ++ context)

    socket
  end

  # One rendering batch for the page rather than a full per-status query set
  # twenty times over.
  defp render_all(statuses, account),
    do: statuses |> Entities.statuses(account, filter_context: "home") |> Enum.reject(&hidden?/1)

  # Every path that puts one post into the stream goes through here. Rendering
  # a live arrival without naming the context meant the same post was filtered
  # on reload and not while somebody watched, which reads as the filter being
  # unreliable rather than as two code paths disagreeing.
  defp insert_one(socket, status, opts \\ []) do
    case render_all([status], socket.assigns.account) do
      [rendered] -> stream_insert(socket, :statuses, rendered, opts)
      # Hidden by one of the reader's own rules. Nothing to insert, and
      # nothing to say about it.
      [] -> socket
    end
  end

  defp oldest_id([]), do: nil
  defp oldest_id(statuses), do: statuses |> Enum.map(& &1.id) |> Enum.min()

  defp newest_id([]), do: nil
  defp newest_id(statuses), do: statuses |> Enum.map(& &1.id) |> Enum.max()
end
