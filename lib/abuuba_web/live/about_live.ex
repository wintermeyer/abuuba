defmodule AbuubaWeb.AboutLive do
  @moduledoc """
  What this server is, who runs it, and what it asks of people.

  Public and server-rendered, because it is what somebody reads before deciding
  whether to sign up here and what a moderator elsewhere reads before deciding
  whether to talk to us.

  The numbers come from the same function the instance document uses, so this
  page and the API cannot disagree about how many people are here.
  """

  use AbuubaWeb, :live_view

  alias Abuuba.Instance
  alias Abuuba.Settings
  alias AbuubaWeb.Formats

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("About"),
       title: Settings.get("site_title") || Instance.software_name(),
       description: Settings.get("extended_description") || "",
       # `site_contact_email` is what the admin screen writes. This read
       # `contact_email`, which nothing writes, so the address an admin filled
       # in was missing from the page whose job is to carry it.
       contact: Settings.get("site_contact_email") || "",
       rules: Settings.rules(),
       usage: Instance.usage(),
       registration_mode: Settings.registration_mode()
     )}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <div class="space-y-6 p-6">
        <section>
          <h1 class="text-3xl font-semibold">{@title}</h1>
          <p class="mt-2 text-base-content/80">
            {gettext("A server on the fediverse, running %{software}.",
              software: Instance.software_name()
            )}
          </p>
          <p :if={@description != ""} class="mt-3 whitespace-pre-wrap">{@description}</p>
        </section>

        <section>
          <h2 class="text-xl font-semibold">{gettext("The numbers")}</h2>
          <dl class="mt-2 grid gap-3 sm:grid-cols-3">
            <div :for={{label, value} <- numbers(@usage)} class="rounded-box bg-base-200 p-3">
              <dt class="text-sm text-base-content/60">{label}</dt>
              <dd class="text-2xl font-semibold tabular-nums">{Formats.number(value)}</dd>
            </div>
          </dl>
        </section>

        <section>
          <h2 class="text-xl font-semibold">{gettext("Signing up")}</h2>
          <p class="mt-2">{registration_note(@registration_mode)}</p>
        </section>

        <section :if={@rules != []}>
          <h2 class="text-xl font-semibold">{gettext("The rules")}</h2>
          <ol class="mt-2 list-decimal space-y-2 pl-6">
            <li :for={rule <- @rules}>
              {rule.text}
              <span :if={rule.hint not in [nil, ""]} class="block text-sm text-base-content/60">
                {rule.hint}
              </span>
            </li>
          </ol>
        </section>

        <section>
          <h2 class="text-xl font-semibold">{gettext("Getting in touch")}</h2>
          <p :if={@contact != ""} class="mt-2">
            <a href={"mailto:" <> @contact} class="link">{@contact}</a>
          </p>
          <p :if={@contact == ""} class="mt-2 text-base-content/60">
            {gettext("Whoever runs this server has not published an address yet.")}
          </p>
        </section>

        <section>
          <h2 class="text-xl font-semibold">{gettext("The small print")}</h2>
          <ul class="mt-2 space-y-1">
            <li><a href={~p"/terms"} class="link">{gettext("Terms of service")}</a></li>
            <li><a href={~p"/privacy"} class="link">{gettext("Privacy policy")}</a></li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp numbers(usage) do
    [
      {gettext("people"), usage.users},
      {gettext("posts"), usage.statuses},
      {gettext("servers known"), usage.domains},
      {gettext("people active this month"), usage.active_month},
      {gettext("people active this half-year"), usage.active_halfyear}
    ]
  end

  defp registration_note(:open), do: gettext("Registration is open: anybody may sign up.")

  defp registration_note(:approved),
    do: gettext("Registration needs approval: you sign up and an admin reads your request.")

  defp registration_note(:closed),
    do: gettext("Registration is closed here, but any other server on the network will do.")

  defp registration_note(_mode), do: ""
end
