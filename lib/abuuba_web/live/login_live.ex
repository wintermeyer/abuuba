defmodule AbuubaWeb.LoginLive do
  @moduledoc """
  The sign-in form.

  The form posts to a plain controller rather than handling the submit here,
  because setting a session cookie needs a real request: a LiveView is talking
  over a socket and has no response to put one on.
  """

  use AbuubaWeb, :live_view

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Sign in"))
     |> assign(:form, to_form(%{}, as: :user)), temporary_assigns: [form: nil]}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm px-4 py-10">
        <h1 class="text-xl font-semibold">{gettext("Sign in")}</h1>

        <.form for={@form} id="login-form" action={~p"/login"} method="post" class="mt-6 space-y-4">
          <.input
            field={@form[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("Password")}
            autocomplete="current-password"
            required
          />
          <.input field={@form[:remember_me]} type="checkbox" label={gettext("Keep me signed in")} />

          <div class="hidden" aria-hidden="true">
            <label for="user_website">{gettext("Leave this field empty")}</label>
            <input
              type="text"
              name="user[website]"
              id="user_website"
              tabindex="-1"
              autocomplete="off"
            />
          </div>

          <button
            type="submit"
            phx-disable-with={gettext("Signing in…")}
            class="w-full rounded-lg bg-zinc-900 px-4 py-2 font-medium text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            {gettext("Sign in")}
          </button>
        </.form>

        <p class="mt-4 text-sm text-zinc-600 dark:text-zinc-400">
          <.link navigate={~p"/reset-password"} class="underline">
            {gettext("Forgotten your password?")}
          </.link>
        </p>

        <p class="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
          {gettext("No account yet?")}
          <.link navigate={~p"/register"} class="underline">{gettext("Create one")}</.link>
        </p>
      </div>
    </Layouts.app>
    """
  end
end
