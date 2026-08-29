defmodule AbuubaWeb.NotificationSettingsLive do
  @moduledoc """
  Who can reach you, and what happens when somebody who cannot tries.

  ## Its own page

  Six axes, three decisions each, and one of the decisions throws things away.
  That is not a menu behind a cog: somebody setting it is making a decision
  about who can talk to them, and it deserves the room to say what each choice
  does.

  ## Ignore is the one that needs a warning

  Filtering files a notification in the requests inbox, where it can still be
  read and accepted. Ignoring drops it, and nothing anywhere remembers it
  happened. The two sound similar and are not, so the page says which is which
  rather than leaving somebody to find out by missing something.
  """

  use AbuubaWeb, :live_view

  alias Abuuba.Notifications
  alias Abuuba.Notifications.Policy

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    account = current_account(socket)

    {:ok,
     socket
     |> assign(page_title: gettext("Notifications"), account: account, saved?: false, error: nil)
     |> load()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <div class="p-4">
        <h2 class="text-xl font-semibold">{gettext("Who can reach you")}</h2>

        <p class="mt-2 text-base-content/70">
          {gettext(
            "Each of these describes a kind of sender. Accept lets them through, Filter puts them in the waiting list on your notifications page, and Ignore drops them."
          )}
        </p>

        <p class="mt-2 rounded bg-warning/10 p-3 text-sm" role="note">
          {gettext(
            "Ignore is the one to be careful with: nothing is filed anywhere and it cannot be recovered. Filter is the reversible one."
          )}
        </p>

        <p :if={@saved?} class="mt-3 text-sm text-success" role="status">{gettext("Saved.")}</p>
        <p :if={@error} class="mt-3 text-sm text-error" role="alert">{@error}</p>

        <form id="notification-policy" phx-submit="save" class="mt-4 space-y-4">
          <fieldset :for={axis <- axes()} class="rounded-box border border-base-300 p-3">
            <legend class="px-1 font-medium">{axis_label(axis)}</legend>
            <p class="mb-2 text-sm text-base-content/60">{axis_hint(axis)}</p>

            <div class="flex flex-wrap gap-4">
              <label :for={decision <- decisions()} class="flex items-center gap-2">
                <input
                  type="radio"
                  name={"policy[#{axis}]"}
                  value={decision}
                  checked={Map.get(@policy, axis) == decision}
                  class="radio radio-sm"
                />
                {decision_label(decision)}
              </label>
            </div>
          </fieldset>

          <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
        </form>
      </div>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"policy" => attrs}, socket) do
    # Only the axes, so nothing else in the body can reach the changeset.
    wanted = Map.take(attrs, Enum.map(Policy.axes(), &to_string/1))

    case Notifications.put_policy(socket.assigns.account, wanted) do
      {:ok, _policy} ->
        {:noreply, socket |> assign(saved?: true, error: nil) |> load()}

      {:error, _changeset} ->
        {:noreply,
         assign(socket, saved?: false, error: gettext("That could not be saved. Try again."))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load(socket) do
    assign(socket, policy: Notifications.policy(socket.assigns.account))
  end

  defp axes, do: Policy.axes()
  defp decisions, do: Policy.decisions()

  defp axis_label(:for_not_following), do: gettext("People you do not follow")
  defp axis_label(:for_not_followers), do: gettext("People who do not follow you")
  defp axis_label(:for_new_accounts), do: gettext("Accounts made very recently")
  defp axis_label(:for_private_mentions), do: gettext("Private mentions out of nowhere")
  defp axis_label(:for_limited_accounts), do: gettext("Accounts a moderator has limited")
  defp axis_label(:for_bots), do: gettext("Automated accounts")
  defp axis_label(axis), do: to_string(axis)

  defp axis_hint(:for_not_following),
    do: gettext("Anybody you have not chosen to follow.")

  defp axis_hint(:for_not_followers),
    do: gettext("Anybody who does not follow you back.")

  defp axis_hint(:for_new_accounts),
    do: gettext("An account registered in the last few days, which is what a spammer uses.")

  defp axis_hint(:for_private_mentions),
    do: gettext("A private message from somebody who is not replying to anything you wrote.")

  defp axis_hint(:for_limited_accounts),
    do: gettext("Somebody a moderator here has already restricted.")

  defp axis_hint(:for_bots), do: gettext("An account that says it posts automatically.")
  defp axis_hint(_axis), do: ""

  defp decision_label("accept"), do: gettext("Accept")
  defp decision_label("filter"), do: gettext("Filter")
  defp decision_label("drop"), do: gettext("Ignore")
  defp decision_label(decision), do: decision
end
