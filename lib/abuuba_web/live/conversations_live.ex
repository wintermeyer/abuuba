defmodule AbuubaWeb.ConversationsLive do
  @moduledoc """
  Direct messages, grouped by who is in them.

  ## Why an inbox rather than a timeline

  Twenty messages back and forth is one conversation somebody is having, not
  twenty things to read. A timeline of direct messages would report the same
  exchange over and over and bury the one that started an hour ago under the
  one that is still going.

  The grouping is the context's (`Abuuba.Conversations`), and it groups by the
  set of people rather than by the thread: a conversation that gained somebody
  halfway through is a different conversation to the person who has to decide
  what to say next.

  ## Opening one marks it read

  The read flag exists to answer "is there anything waiting", so the moment
  somebody looks is the moment the answer changes. A separate "mark read"
  button as the only way would leave a count that only ever goes up.

  The thread itself is the post page, which already renders a conversation with
  its replies and its ancestors. A second thread renderer here would be a
  second place for the same bugs.
  """

  use AbuubaWeb, :live_view

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Conversations
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Formatter
  alias Abuuba.Streaming
  alias AbuubaWeb.API.Entities

  @page_size 20

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Streaming.subscribe(Streaming.account_topic(current_account(socket)))

    {:ok, socket |> assign(page_title: gettext("Messages")) |> load()}
  end

  # A message arriving while somebody is looking at their inbox. The whole page
  # is reloaded rather than the one row patched: an inbox is twenty rows and
  # the arriving message may reorder them, which is most of what the reader
  # needs to see.
  @impl Phoenix.LiveView
  def handle_info({:streaming, "conversation", _row}, socket), do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <h1 class="p-4 text-xl font-semibold">{gettext("Messages")}</h1>

      <p :if={@rows == []} class="px-4 pb-6 text-base-content/70">
        {gettext(
          "Nothing here yet. A post addressed to only the people you name arrives as a message, and its replies stay with it."
        )}
      </p>

      <ul class="divide-y divide-base-300">
        <li :for={row <- @rows} class="p-4" id={"conversation-#{row.id}"}>
          <div class="flex items-start gap-3">
            <span
              :if={row.unread}
              class="mt-2 size-2 shrink-0 rounded-full bg-primary"
              aria-hidden="true"
            ></span>

            <button
              type="button"
              phx-click="open"
              phx-value-id={row.id}
              class="grow text-left"
              aria-label={gettext("Open the conversation with %{people}", people: row.people)}
            >
              <span class={["block", row.unread && "font-semibold"]}>{row.people}</span>
              <span class="mt-1 block text-sm text-base-content/70">{row.excerpt}</span>
              <span :if={row.unread} class="sr-only">{gettext("unread")}</span>
            </button>

            <span class="flex shrink-0 gap-2">
              <button
                :if={not row.unread}
                type="button"
                phx-click="unread"
                phx-value-id={row.id}
                class="btn btn-sm btn-ghost"
              >
                {gettext("Mark unread")}
              </button>

              <button
                type="button"
                phx-click="remove"
                phx-value-id={row.id}
                data-confirm={
                  gettext(
                    "This takes it out of your inbox only. Nobody else loses anything, and a later message brings it back. Go ahead?"
                  )
                }
                class="btn btn-sm btn-ghost"
              >
                {gettext("Remove")}
              </button>
            </span>
          </div>
        </li>
      </ul>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("open", %{"id" => id}, socket) do
    account = current_account(socket)

    case Conversations.get(account, id) do
      nil ->
        {:noreply, load(socket)}

      row ->
        Conversations.mark_read(account, row.id)

        {:noreply, push_navigate(socket, to: path_to(row, account))}
    end
  end

  def handle_event("unread", %{"id" => id}, socket) do
    Conversations.mark_unread(current_account(socket), id)

    {:noreply, load(socket)}
  end

  def handle_event("remove", %{"id" => id}, socket) do
    Conversations.remove(current_account(socket), id)

    {:noreply, load(socket)}
  end

  # The last message's own page, which renders the thread around it. A
  # conversation whose last message has since been deleted keeps its row and
  # its people, so this falls back to the inbox rather than to a 404.
  defp path_to(row, account) do
    with id when not is_nil(id) <- row.last_status_id,
         %{} = status <- Statuses.get_status(id, account),
         %{} = author <- Accounts.get_account(status.account_id) do
      ~p"/@#{Account.acct(author)}/#{status.id}"
    else
      _ -> ~p"/conversations"
    end
  end

  defp load(socket) do
    account = current_account(socket)
    rows = Conversations.list(account, %{limit: @page_size})

    # One query for every name on the page and one for every last message,
    # rather than two per row.
    people =
      rows
      |> Enum.flat_map(&List.wrap(&1.participant_account_ids))
      |> Enum.uniq()
      |> Accounts.get_accounts()

    last =
      rows
      |> Enum.map(& &1.last_status_id)
      |> Enum.reject(&is_nil/1)
      |> Statuses.get_visible_statuses(account)

    # Rendered in one batch like the names and the messages above. Rendering
    # each row's post on its own asked the fourteen-odd questions behind an
    # entity once per row, for a page that keeps one line of the answer.
    excerpts =
      last
      |> Entities.statuses(account)
      |> Map.new(&{&1["id"], &1["content"]})

    assign(socket, rows: Enum.map(rows, &decorate(&1, account, people, excerpts)))
  end

  defp decorate(row, account, people, excerpts) do
    %{
      id: row.id,
      unread: row.unread,
      people: people(row, account, people),
      excerpt: excerpt(row, excerpts)
    }
  end

  # Everybody but the reader. A conversation with nobody else in it is one
  # somebody addressed to themselves, and naming them is better than an empty
  # line where a name goes.
  defp people(row, account, known) do
    row.participant_account_ids
    |> List.wrap()
    |> Enum.reject(&(&1 == account.id))
    |> Enum.flat_map(&List.wrap(Map.get(known, &1)))
    |> Enum.map_join(", ", &("@" <> Account.acct(&1)))
    |> case do
      "" -> "@" <> Account.acct(account)
      names -> names
    end
  end

  # The words rather than the markup: this is one line in a list, and a
  # rendered post here would bring its pictures, its poll and its buttons with
  # it.
  @excerpt_length 140

  defp excerpt(row, excerpts) do
    with id when not is_nil(id) <- row.last_status_id,
         content when is_binary(content) <- Map.get(excerpts, to_string(id)) do
      Formatter.plain_text(content, limit: @excerpt_length)
    else
      _ -> gettext("The last message has been deleted.")
    end
  end
end
