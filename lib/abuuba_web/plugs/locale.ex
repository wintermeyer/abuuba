defmodule AbuubaWeb.Plugs.Locale do
  @moduledoc """
  Puts the reader's locale in force for the rest of the request.

  Sets it on Gettext and on CLDR both, because they answer different halves of
  the same question and a page translated into German with English dates reads
  worse than one that never tried.

  The resolved locale is also assigned, so a template can mark up
  `<html lang>` and a language picker can show which entry is current.
  """

  import Plug.Conn

  alias Abuuba.Accounts.User
  alias Abuuba.I18n

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    header = accept_language(conn)

    locale =
      I18n.resolve(
        user_locale: current_user_locale(conn),
        session_locale: session_locale(conn),
        accept_language: header
      )

    put_locale(locale)

    conn
    |> remember_accept_language(header)
    |> assign(:locale, locale)
  end

  # The hook that runs when a LiveView mounts has no request to read, and
  # nearly every page here is a LiveView. Without this the hook resolved from
  # the account and the session alone and fell back to English, so a German
  # browser was answered in English however plainly it had asked.
  #
  # The header rather than the locale it resolves to, so the hook makes the
  # same decision from the same three sources in the same order: a stored
  # preference still wins, and this is only what the browser asked for.
  defp remember_accept_language(conn, nil), do: conn

  defp remember_accept_language(conn, header) do
    case conn.private do
      # Rewritten only when it changes, so an unchanged session does not send
      # a fresh cookie on every request.
      %{plug_session: _session} ->
        if get_session(conn, :accept_language) == header,
          do: conn,
          else: put_session(conn, :accept_language, header)

      _no_session ->
        conn
    end
  end

  # The API pipeline has no session, and a reader asking an API in German is
  # asking the same question as a reader asking a page in German.
  defp session_locale(conn) do
    # `:plug_session` appears only once a session has actually been fetched,
    # which the API pipeline never does.
    case conn.private do
      %{plug_session: _session} -> get_session(conn, :locale)
      _ -> nil
    end
  end

  @doc """
  Applies a locale to this process. Also called from the LiveView hook, which
  runs in a process of its own and so inherits nothing from the request.
  """
  @spec put_locale(String.t()) :: :ok
  def put_locale(locale) do
    Gettext.put_locale(AbuubaWeb.Gettext, locale)
    Abuuba.Cldr.put_locale(locale)

    :ok
  end

  defp current_user_locale(conn) do
    case conn.assigns[:current_scope] do
      %{user: %User{locale: locale}} -> locale
      _ -> nil
    end
  end

  defp accept_language(conn) do
    conn |> get_req_header("accept-language") |> List.first()
  end
end
