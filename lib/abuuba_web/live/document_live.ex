defmodule AbuubaWeb.DocumentLive do
  @moduledoc """
  The terms of service and the privacy policy.

  ## Written by an admin, not by us

  These are legal statements about one particular server, and shipping default
  text would mean shipping a claim its operator never made. So the page shows
  whatever they wrote and says plainly when they have written nothing, which
  reads as honest rather than broken and tells an admin what is missing.

  ## The date is part of the document

  Terms somebody agreed to in March are not the terms that appeared in
  September, so the page carries the date the current text took effect and
  every older version stays readable at its own address. Without that, "the
  terms" names a moving thing.
  """

  use AbuubaWeb, :live_view

  alias Abuuba.Instance
  alias Abuuba.Settings
  alias AbuubaWeb.Formats

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, kind: socket.assigns.live_action)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    kind = socket.assigns.kind

    {:noreply,
     socket
     |> assign(page_title: title(kind), versions: versions(kind))
     |> assign(document(kind, params["date"]))}
  end

  # Terms are versioned rows; the privacy policy is still a single piece of
  # text an admin writes in settings. Asking for a date nobody published shows
  # the current version rather than an error page: a stale link in somebody's
  # email is not a reason to show them nothing.
  defp document(:terms, date) do
    case terms(date) do
      # Terms are rows, one per version, so that somebody can still read what
      # they agreed to. There used to be a settings fallback here as well, and
      # no screen wrote the keys it read: a second source of truth that could
      # never be filled, and an empty string dressed up as a document.
      nil -> %{text: "", effective_on: nil}
      terms -> %{text: terms.text, effective_on: terms.effective_date}
    end
  end

  defp document(kind, _date) do
    %{
      text: Settings.get(key(kind, "text")) || "",
      effective_on: Settings.get(key(kind, "effective_on"))
    }
  end

  # The two branches above disagree about shape: terms are rows and carry a
  # `%Date{}`, while the privacy policy is a settings string an admin typed.
  # Both reach the same sentence, so both are turned into the reader's date
  # here. Anything that will not parse is passed through as written rather
  # than swallowed: if an admin typed something odd into the settings box, the
  # page should show what is stored and not quietly go blank.
  defp reader_date(%Date{} = date), do: Formats.date(date)

  defp reader_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Formats.date(date)
      _ -> value
    end
  end

  defp reader_date(value), do: value

  defp terms(nil), do: Instance.current_terms()

  defp terms(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> Instance.terms_for(date) || Instance.current_terms()
      _ -> Instance.current_terms()
    end
  end

  defp versions(:terms), do: Instance.terms_versions(%{limit: 20})
  defp versions(_kind), do: []

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <div class="p-6">
        <h1 class="text-3xl font-semibold">{title(@kind)}</h1>

        <p :if={@effective_on} class="mt-1 text-sm text-base-content/60">
          {gettext("In effect since %{date}", date: reader_date(@effective_on))}
        </p>

        <div :if={@text != ""} class="mt-4 whitespace-pre-wrap break-words">{@text}</div>

        <p :if={@text == ""} class="mt-4 text-base-content/70">
          {gettext(
            "This has not been written yet. Whoever runs this server can add it in the admin settings."
          )}
        </p>

        <section :if={length(@versions) > 1} class="mt-6">
          <h2 class="font-semibold">{gettext("Earlier versions")}</h2>
          <ul class="mt-1 space-y-1">
            <li :for={version <- @versions}>
              <%!-- The path keeps the ISO date: it is an address, not a date
                    somebody reads. The label beside it is the one they read. --%>
              <.link navigate={~p"/terms/#{version.effective_date}"} class="link">
                {gettext("In effect from %{date}", date: reader_date(version.effective_date))}
              </.link>
            </li>
          </ul>
        </section>

        <p class="mt-6">
          <a href={~p"/about"} class="link">{gettext("About this server")}</a>
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp title(:terms), do: gettext("Terms of service")
  defp title(:privacy), do: gettext("Privacy policy")
  defp title(_kind), do: gettext("About")

  defp key(:privacy, suffix), do: "privacy_" <> suffix
  defp key(_kind, suffix), do: suffix
end
