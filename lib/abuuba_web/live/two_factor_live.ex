defmodule AbuubaWeb.TwoFactorLive do
  @moduledoc """
  The second step of signing in.

  One field takes either an authenticator code or a recovery code. Somebody
  reaching for a recovery code has already lost their phone, and making them
  find a second form at that moment is exactly the wrong time to add a step.
  """

  use AbuubaWeb, :live_view

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Two-factor authentication"))
     |> assign(:form, to_form(%{}, as: :user))}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm px-4 py-10">
        <h1 class="text-xl font-semibold">{gettext("One more step")}</h1>
        <p class="mt-2 text-zinc-600 dark:text-zinc-400">
          {gettext("Enter the code from your authenticator app, or one of your recovery codes.")}
        </p>

        <.form
          for={@form}
          id="two-factor-form"
          action={~p"/login/two-factor"}
          method="post"
          class="mt-6 space-y-4"
        >
          <.input
            field={@form[:code]}
            type="text"
            label={gettext("Code")}
            autocomplete="one-time-code"
            inputmode="text"
            required
          />

          <button
            type="submit"
            phx-disable-with={gettext("Checking…")}
            class="w-full rounded-lg bg-zinc-900 px-4 py-2 font-medium text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            {gettext("Continue")}
          </button>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
