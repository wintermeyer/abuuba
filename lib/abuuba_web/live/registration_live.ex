defmodule AbuubaWeb.RegistrationLive do
  @moduledoc """
  Signing up, as a wizard with the rules first.

  The order is the point. Putting the server rules in front of the form, rather
  than as a checkbox beneath it, is the difference between somebody having read
  them and somebody having ticked a box. It also lets a person find out this
  server is not for them before they have typed anything in.
  """

  use AbuubaWeb, :live_view

  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.Registration
  alias Abuuba.Invites
  alias Abuuba.Invites.Invite
  alias Abuuba.Moderation.Signup.Captcha
  alias Abuuba.RateLimit

  @signups 5
  @signup_window 30 * 60 * 1000
  alias Abuuba.Settings

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    rules = Settings.rules()
    mode = Settings.registration_mode()
    # Looked up whatever state it is in, so that an expired or exhausted code
    # can be said out loud. Only a usable one counts as an invitation for
    # everything that follows: the step somebody starts on, the reason field,
    # and the hidden code the form submits.
    presented = Invites.get_by_code(params["invite"])
    invite = if presented && Invite.usable?(presented), do: presented

    {:ok,
     socket
     |> assign(:page_title, gettext("Create an account"))
     |> assign(:rules, rules)
     |> assign(:mode, mode)
     |> assign(:invite, invite)
     |> assign(:invite_problem, invite_problem(params["invite"], presented))
     # Known only once the socket has connected, which is before anybody can
     # submit: the form is a LiveView and the first, HTTP-rendered mount has no
     # peer to read. See `AbuubaWeb.ClientIP.of_socket/1`.
     |> assign(:client_ip, AbuubaWeb.ClientIP.of_socket(socket))
     |> assign(:captcha_site_key, Captcha.site_key())
     |> assign(:captcha_error, nil)
     |> assign(:step, first_step(rules, mode, invite))
     # Answered by the registration once there is one. Defaulted here so the
     # done screen never renders against an assign that does not exist yet.
     |> assign(:awaiting_approval?, false)
     |> assign(
       :form,
       to_form(
         Registration.changeset(%{"invite_code" => invite && invite.code},
           rules_required: rules != []
         ),
         as: :user
       )
     )}
  end

  @impl Phoenix.LiveView
  def handle_event("accept_rules", _params, socket) do
    {:noreply, assign(socket, :step, :details)}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      params
      |> Registration.changeset(rules_required: socket.assigns.rules != [])
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :user))}
  end

  def handle_event("submit", %{"user" => params} = event, socket) do
    params = Map.put(params, "locale", socket.assigns[:locale])

    # Counted here rather than by a plug, because this form submits over the
    # socket and a plug never sees it. `POST /api/v1/accounts` has been counted
    # per address since it was written; this is the same door and it was open.
    # Every sign-up sends a confirmation to an address whoever is typing chose,
    # so an unbounded form is a way to make this server mail strangers until
    # its domain is refused everywhere.
    case RateLimit.hit(signup_key(socket), limit: @signups, window_ms: @signup_window) do
      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, signup_limit_message())}

      {:ok, _remaining} ->
        case Captcha.verify(event["h-captcha-response"]) do
          :ok -> register(socket, params)
          {:error, reason} -> {:noreply, assign(socket, :captcha_error, captcha_message(reason))}
        end
    end
  end

  # The same five per half hour the API door allows, so the two answers agree.
  defp signup_key(socket), do: "signup_form:#{socket.assigns.client_ip}"

  defp signup_limit_message do
    gettext("Too many sign-ups from here just now. Please try again later.")
  end

  defp captcha_message(:captcha_missing),
    do: gettext("Please complete the puzzle so we know you are a person.")

  defp captcha_message(:captcha_unavailable),
    do: gettext("The puzzle could not be checked just now. Please try again in a moment.")

  defp captcha_message(_reason), do: gettext("That puzzle answer was not accepted.")

  defp register(socket, params) do
    opts = [rules_required: socket.assigns.rules != [], ip: socket.assigns.client_ip]

    case Auth.register(params, opts) do
      {:ok, %{user: user}} ->
        Auth.deliver_signup_mail(user, &url(~p"/confirm/#{&1}"))

        {:noreply,
         socket
         |> assign(:step, :done)
         |> assign(:registered_email, user.email)
         |> assign(:awaiting_approval?, not user.approved)}

      {:error, :registration_closed} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("This server is not accepting new accounts right now."))
         |> assign(:step, :closed)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :user))}
    end
  end

  # An invite is a person here vouching, which is exactly what a closed server
  # leaves room for. The rules still come first: being invited is not the same
  # as having read them.
  defp first_step(rules, :closed, nil), do: first_step_when_closed(rules)
  defp first_step([], _mode, _invite), do: :details
  defp first_step(_rules, _mode, _invite), do: :rules

  # Said plainly and separately from "no such code", because the three are
  # different things to the person holding the link: one is a typo, one is a
  # link that sat in a mailbox too long, and one is a link that went round a
  # group chat. Somebody who was genuinely invited should be able to tell which
  # happened to them without asking whoever invited them.
  defp invite_problem(nil, _presented), do: nil
  defp invite_problem("", _presented), do: nil

  defp invite_problem(_code, nil), do: gettext("That invitation is not one we know.")

  defp invite_problem(_code, invite) do
    cond do
      Invite.expired?(invite, DateTime.utc_now()) -> gettext("That invitation has expired.")
      Invite.used_up?(invite) -> gettext("That invitation has been used up.")
      true -> nil
    end
  end

  defp first_step_when_closed(_rules), do: :closed

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-lg px-4 py-10">
        <.progress :if={@step in [:rules, :details, :done]} step={@step} has_rules={@rules != []} />

        <div :if={@step == :closed} class="rounded-lg border border-zinc-300 p-6 dark:border-zinc-700">
          <h1 class="text-xl font-semibold">{gettext("Registrations are closed")}</h1>
          <p class="mt-2 text-zinc-600 dark:text-zinc-400">
            {gettext(
              "This server is not taking new accounts at the moment. You can join the fediverse from any other server and still follow people here."
            )}
          </p>
        </div>

        <div :if={@step == :rules}>
          <h1 class="text-xl font-semibold">{gettext("The rules here")}</h1>
          <p class="mt-2 text-zinc-600 dark:text-zinc-400">
            {gettext("Please read these before you sign up. They are what moderation goes by.")}
          </p>

          <ol class="mt-6 space-y-4">
            <li
              :for={rule <- @rules}
              class="rounded-lg border border-zinc-200 p-4 dark:border-zinc-800"
            >
              <p class="font-medium">{rule.text}</p>
              <p :if={rule.hint != ""} class="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
                {rule.hint}
              </p>
            </li>
          </ol>

          <button
            phx-click="accept_rules"
            class="mt-6 w-full rounded-lg bg-zinc-900 px-4 py-2 font-medium text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            {gettext("I have read the rules")}
          </button>
        </div>

        <div :if={@step == :details}>
          <h1 class="text-xl font-semibold">{gettext("Create an account")}</h1>

          <.form
            for={@form}
            id="registration-form"
            phx-change="validate"
            phx-submit="submit"
            class="mt-6 space-y-4"
          >
            <.input
              field={@form[:username]}
              type="text"
              label={gettext("Username")}
              autocomplete="username"
            />
            <.input field={@form[:email]} type="email" label={gettext("Email")} autocomplete="email" />
            <.input
              field={@form[:password]}
              type="password"
              label={gettext("Password")}
              autocomplete="new-password"
            />
            <p class="text-sm text-zinc-600 dark:text-zinc-400">
              {gettext("At least 12 characters. A sentence you can remember beats a short jumble.")}
            </p>

            <input type="hidden" name="user[invite_code]" value={@invite && @invite.code} />

            <p :if={@invite} class="text-sm text-zinc-600 dark:text-zinc-400">
              {gettext("You are signing up on an invitation, so you do not need to be approved.")}
            </p>

            <p :if={@invite_problem} class="text-sm text-error" role="alert">
              {@invite_problem} {gettext("You can still sign up without one.")}
            </p>

            <.input
              :if={@mode == :approved and is_nil(@invite)}
              field={@form[:invite_reason]}
              type="textarea"
              label={gettext("Why would you like to join?")}
            />

            <div :if={@captcha_site_key} class="space-y-1">
              <div class="h-captcha" data-sitekey={@captcha_site_key}></div>
              <p class="text-sm text-zinc-600 dark:text-zinc-400">
                {gettext("This server asks new accounts to solve a puzzle first.")}
              </p>
              <p :if={@captcha_error} class="text-sm text-red-600 dark:text-red-400" role="alert">
                {@captcha_error}
              </p>
            </div>

            <.input
              :if={@rules != []}
              field={@form[:agreement]}
              type="checkbox"
              label={gettext("I agree to the server rules")}
            />

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
              phx-disable-with={gettext("Creating your account…")}
              class="w-full rounded-lg bg-zinc-900 px-4 py-2 font-medium text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
            >
              {gettext("Create account")}
            </button>
          </.form>

          <p class="mt-4 text-sm text-zinc-600 dark:text-zinc-400">
            {gettext("Already have an account?")}
            <.link navigate={~p"/login"} class="underline">{gettext("Sign in")}</.link>
          </p>
        </div>

        <div :if={@step == :done} class="rounded-lg border border-zinc-300 p-6 dark:border-zinc-700">
          <h1 class="text-xl font-semibold">{gettext("Check your email")}</h1>
          <p class="mt-2 text-zinc-600 dark:text-zinc-400">
            {gettext("We sent a confirmation link to %{email}.", email: @registered_email)}
          </p>
          <p :if={@awaiting_approval?} class="mt-2 text-zinc-600 dark:text-zinc-400">
            {gettext(
              "After you confirm it, a moderator reads your registration. We will email you when they have."
            )}
          </p>

          <Layouts.dev_mailbox inline />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :step, :atom, required: true
  attr :has_rules, :boolean, required: true

  defp progress(assigns) do
    ~H"""
    <ol class="mb-8 flex items-center gap-2 text-sm">
      <li :if={@has_rules} class={step_class(@step, :rules)}>{gettext("Rules")}</li>
      <li :if={@has_rules} aria-hidden="true" class="text-zinc-400">→</li>
      <li class={step_class(@step, :details)}>{gettext("Your details")}</li>
      <li aria-hidden="true" class="text-zinc-400">→</li>
      <li class={step_class(@step, :done)}>{gettext("Confirm your email")}</li>
    </ol>
    """
  end

  defp step_class(step, step), do: "font-semibold text-zinc-900 dark:text-zinc-100"
  defp step_class(_current, _step), do: "text-zinc-500 dark:text-zinc-500"
end
