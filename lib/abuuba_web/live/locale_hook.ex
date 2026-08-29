defmodule AbuubaWeb.LocaleHook do
  @moduledoc """
  Keeps the locale in force across LiveView navigation.

  A LiveView runs in its own process, which inherits nothing from the request
  that mounted it, and a `live_patch` never touches a plug at all. Without this
  the first page arrives translated and every page after it reverts to English.

  Add to a `live_session`:

      live_session :default, on_mount: AbuubaWeb.LocaleHook do
        live "/", HomeLive
      end
  """

  import Phoenix.Component, only: [assign: 3]

  alias Abuuba.I18n
  alias AbuubaWeb.Plugs.Locale

  def on_mount(:default, _params, session, socket) do
    locale =
      I18n.resolve(
        user_locale: user_locale(socket),
        session_locale: session["locale"],
        # What the browser asked for, put in the session by the plug on the way
        # in: a mount has no request to read it from, and leaving it out
        # answered every visitor in English until they chose otherwise.
        accept_language: session["accept_language"]
      )

    Locale.put_locale(locale)

    {:cont, assign(socket, :locale, locale)}
  end

  defp user_locale(socket) do
    case socket.assigns[:current_scope] do
      %{user: %{locale: locale}} -> locale
      _ -> nil
    end
  end
end
