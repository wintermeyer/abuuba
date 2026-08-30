defmodule AbuubaWeb.TwoFactorSettingsLive do
  @moduledoc """
  Turning a second factor on and off.

  The recovery codes are shown once, on the screen right after enrolment, and
  never again. That is not a limitation to apologise for, it is the reason they
  are safe to store: they are hashed, so there is nothing to show later.
  """

  use AbuubaWeb, :live_view

  alias Abuuba.Accounts.TwoFactor

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:page_title, gettext("Two-factor authentication"))
     |> assign(:user, user)
     |> assign(:enrolment, nil)
     |> assign(:codes, nil)
     |> assign(:form, to_form(%{}, as: :otp))
     |> assign(:remaining, TwoFactor.unused_recovery_code_count(user))}
  end

  @impl Phoenix.LiveView
  def handle_event("begin", _params, socket) do
    {:ok, enrolment} = TwoFactor.begin_totp_enrolment(socket.assigns.user)

    {:noreply, assign(socket, :enrolment, enrolment)}
  end

  def handle_event("confirm", %{"otp" => %{"code" => code}}, socket) do
    user = Abuuba.Repo.get!(Abuuba.Accounts.User, socket.assigns.user.id)

    case TwoFactor.confirm_totp_enrolment(user, code) do
      {:ok, enrolled, codes} ->
        {:noreply,
         socket
         |> assign(:user, enrolled)
         |> assign(:enrolment, nil)
         |> assign(:codes, codes)
         |> assign(:remaining, length(codes))
         |> put_flash(:info, gettext("Two-factor authentication is on."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("That code is not right. Try again."))}
    end
  end

  def handle_event("regenerate", _params, socket) do
    {:ok, codes} = TwoFactor.regenerate_recovery_codes(socket.assigns.user)

    {:noreply,
     socket
     |> assign(:codes, codes)
     |> assign(:remaining, length(codes))
     |> put_flash(:info, gettext("Your old recovery codes no longer work."))}
  end

  def handle_event("disable", _params, socket) do
    {:ok, user} = TwoFactor.disable(socket.assigns.user)

    {:noreply,
     socket
     |> assign(:user, user)
     |> assign(:codes, nil)
     |> assign(:remaining, 0)
     |> put_flash(:info, gettext("Two-factor authentication is off."))}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-lg px-4 py-10">
        <h1 class="text-xl font-semibold">{gettext("Two-factor authentication")}</h1>

        <div :if={@codes} class="mt-6 rounded-lg border border-amber-400 p-4">
          <h2 class="font-semibold">{gettext("Save these recovery codes now")}</h2>
          <p class="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
            {gettext(
              "This is the only time they are shown. Each one works once, and they are how you get back in if you lose your phone."
            )}
          </p>
          <ul class="mt-3 grid grid-cols-2 gap-2 font-mono text-sm">
            <li :for={code <- @codes}>{code}</li>
          </ul>
        </div>

        <div :if={is_nil(@enrolment) and not TwoFactor.required?(@user)} class="mt-6">
          <p class="text-zinc-600 dark:text-zinc-400">
            {gettext(
              "A second factor means somebody who learns your password still cannot sign in as you."
            )}
          </p>
          <button
            phx-click="begin"
            class="mt-4 rounded-lg bg-zinc-900 px-4 py-2 font-medium text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            {gettext("Set up an authenticator app")}
          </button>
        </div>

        <div :if={@enrolment} class="mt-6">
          <p class="text-zinc-600 dark:text-zinc-400">
            {gettext("Scan this with your authenticator app, then type the code it shows.")}
          </p>

          <div class="mt-4">{Phoenix.HTML.raw(@enrolment.qr_code)}</div>

          <p class="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
            {gettext("Cannot scan it? Type this in instead:")}
            <code class="font-mono">{Base.encode32(@enrolment.secret, padding: false)}</code>
          </p>

          <.form for={@form} id="confirm-otp-form" phx-submit="confirm" class="mt-4 space-y-4">
            <.input
              field={@form[:code]}
              type="text"
              label={gettext("Code")}
              autocomplete="one-time-code"
            />
            <button
              type="submit"
              class="rounded-lg bg-zinc-900 px-4 py-2 font-medium text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
            >
              {gettext("Turn it on")}
            </button>
          </.form>
        </div>

        <div :if={is_nil(@enrolment) and TwoFactor.required?(@user)} class="mt-6 space-y-4">
          <p class="text-zinc-600 dark:text-zinc-400">
            {ngettext(
              "Two-factor authentication is on. You have 1 recovery code left.",
              "Two-factor authentication is on. You have %{count} recovery codes left.",
              @remaining
            )}
          </p>

          <button phx-click="regenerate" class="rounded-lg border px-4 py-2 font-medium">
            {gettext("Make new recovery codes")}
          </button>

          <button
            phx-click="disable"
            data-confirm={gettext("Turn off two-factor authentication?")}
            class="rounded-lg border border-red-500 px-4 py-2 font-medium text-red-600 dark:text-red-400"
          >
            {gettext("Turn it off")}
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
