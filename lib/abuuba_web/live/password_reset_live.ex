defmodule AbuubaWeb.PasswordResetLive do
  @moduledoc """
  The two pages of a password reset: asking for a link, and using one.

  ## The link is checked before the field is shown

  Opening a reset link with an expired token says so straight away rather than
  after somebody has thought of a password and typed it twice. The token itself
  is never rendered into the page body — it goes in the form's action, which is
  where it was already, in the address bar.

  ## What this page will not say

  Neither page ever indicates whether an address has an account here. The
  request page answers identically for both, and this one says only that a link
  is no longer good, never whose it was.
  """

  use AbuubaWeb, :live_view

  alias Abuuba.Accounts.Auth

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    {:ok, socket |> assign(:form, to_form(%{}, as: :user)) |> assign_token(params)}
  end

  defp assign_token(socket, %{"token" => token}) do
    socket
    |> assign(:page_title, gettext("Set a new password"))
    |> assign(:token, token)
    |> assign(:valid?, not is_nil(Auth.get_user_by_reset_token(token)))
  end

  defp assign_token(socket, _params) do
    socket
    |> assign(:page_title, gettext("Forgotten password"))
    |> assign(:token, nil)
    |> assign(:valid?, false)
  end

  @impl Phoenix.LiveView
  def render(%{token: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <div class="mx-auto max-w-sm px-4 py-10">
        <h1 class="text-xl font-semibold">{gettext("Forgotten password")}</h1>

        <p class="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
          {gettext("Give the address you signed up with and we will send you a link.")}
        </p>

        <.form
          for={@form}
          id="reset-request-form"
          action={~p"/reset-password"}
          method="post"
          class="mt-6 space-y-4"
        >
          <.input
            field={@form[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            required
          />

          <button
            type="submit"
            phx-disable-with={gettext("Sending…")}
            class="w-full rounded-lg bg-zinc-900 px-4 py-2 font-medium text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            {gettext("Send me a link")}
          </button>
        </.form>

        <p class="mt-4 text-sm text-zinc-600 dark:text-zinc-400">
          <.link navigate={~p"/login"} class="underline">{gettext("Back to signing in")}</.link>
        </p>
      </div>
    </Layouts.app>
    """
  end

  def render(%{valid?: false} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <div class="mx-auto max-w-sm px-4 py-10">
        <h1 class="text-xl font-semibold">{gettext("That link is no good any more")}</h1>

        <p class="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
          {gettext("A link works once and lasts a few hours. Ask for a fresh one.")}
        </p>

        <p class="mt-4">
          <.link navigate={~p"/reset-password"} class="underline">
            {gettext("Send me a new link")}
          </.link>
        </p>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <div class="mx-auto max-w-sm px-4 py-10">
        <h1 class="text-xl font-semibold">{gettext("Set a new password")}</h1>

        <.form
          for={@form}
          id="reset-form"
          action={~p"/reset-password/#{@token}"}
          method="post"
          class="mt-6 space-y-4"
        >
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("New password")}
            autocomplete="new-password"
            minlength="12"
            required
          />

          <p class="text-sm text-zinc-600 dark:text-zinc-400">
            {gettext(
              "At least 12 characters. A few words you can remember beat a short one you cannot."
            )}
          </p>

          <button
            type="submit"
            phx-disable-with={gettext("Saving…")}
            class="w-full rounded-lg bg-zinc-900 px-4 py-2 font-medium text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            {gettext("Set the password")}
          </button>
        </.form>

        <p class="mt-4 text-sm text-zinc-600 dark:text-zinc-400">
          {gettext("Everywhere you are signed in will be signed out, including apps.")}
        </p>
      </div>
    </Layouts.app>
    """
  end
end
