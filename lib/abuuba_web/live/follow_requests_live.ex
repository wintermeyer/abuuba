defmodule AbuubaWeb.FollowRequestsLive do
  @moduledoc """
  The people waiting to follow a locked account, and the two answers.

  ## Why it is a screen of its own

  Locking is one switch on the privacy page, and everything that switch
  produces has to land somewhere a person can answer it. It arrived as a
  notification, which is a record that something happened rather than a thing
  to act on, and the only control anywhere in the interface was an accept-all
  in the account-migration section worded for a move. So the switch could be
  turned on and its consequences could not be dealt with.

  Beside the follows rather than inside them, because these are not people the
  reader follows: they are people asking, and the answer is a decision rather
  than a list to tick through.

  ## Turning somebody away tells them nothing

  `Abuuba.Relationships.reject_follow_request/1` removes the row and leaves no
  trace on the asker's side, so they can ask again. That is deliberate, and the
  page says so: somebody who expects a rejection to be final would otherwise
  read a second request as the server having lost the first.
  """

  use AbuubaWeb, :live_view

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Relationships
  alias Abuuba.Snowflake

  @page_size 100

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: gettext("Follow requests")) |> load()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <h1 class="p-4 text-xl font-semibold">{gettext("Follow requests")}</h1>

      <p :if={@requests != []} class="px-4 pb-2 text-base-content/70">
        {gettext(
          "Your account asks before letting somebody follow it. Turning one away tells them nothing, and they can ask again."
        )}
      </p>

      <p :if={@requests == []} class="px-4 pb-6 text-base-content/70">
        {gettext("Nobody is waiting. Anybody who asks to follow you turns up here.")}
      </p>

      <ul class="divide-y divide-base-300">
        <li :for={person <- @requests} class="flex flex-wrap items-center gap-3 p-4">
          <span class="min-w-0 flex-1">
            <.link navigate={~p"/@#{Account.acct(person)}"} class="font-medium">
              {Account.display_name(person)}
            </.link>
            <span class="block text-sm text-base-content/60">@{Account.acct(person)}</span>
          </span>

          <span class="flex shrink-0 gap-2">
            <button
              type="button"
              phx-click="accept"
              phx-value-id={person.id}
              class="btn btn-sm btn-primary"
            >
              {gettext("Let them follow")}
            </button>

            <button type="button" phx-click="reject" phx-value-id={person.id} class="btn btn-sm">
              {gettext("Turn them away")}
            </button>
          </span>
        </li>
      </ul>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("accept", %{"id" => id}, socket) do
    {:noreply, answer(socket, id, &Relationships.accept_follow_request/1)}
  end

  def handle_event("reject", %{"id" => id}, socket) do
    {:noreply, answer(socket, id, &Relationships.reject_follow_request/1)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Read back through the reader's own pending list rather than trusted from
  # the button: the id arrives from the page, and the only request this account
  # may answer is one that is waiting on it.
  defp answer(socket, id, decide) do
    account = current_account(socket)

    with {:ok, asker_id} <- Snowflake.cast(id),
         %Account{} = asker <- Accounts.get_account(asker_id),
         %{} = request <- Relationships.get_follow_request(asker, account) do
      decide.(request)
    end

    load(socket)
  end

  defp load(socket) do
    account = current_account(socket)

    assign(socket, requests: Relationships.pending_followers(account, %{limit: @page_size}))
  end
end
