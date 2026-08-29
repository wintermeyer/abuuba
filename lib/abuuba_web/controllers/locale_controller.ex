defmodule AbuubaWeb.LocaleController do
  @moduledoc """
  Switching language.

  The choice is stored in the session, so it survives for a logged-out reader,
  and saved onto the user record as well when there is one, so it survives a
  new browser too.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts
  alias Abuuba.Accounts.User
  alias Abuuba.I18n

  def update(conn, %{"locale" => locale}) do
    if I18n.known?(locale) do
      conn
      |> put_session(:locale, locale)
      |> remember_for_user(locale)
      |> redirect(to: return_path(conn))
    else
      conn
      |> put_flash(:error, gettext("That language is not available."))
      |> redirect(to: return_path(conn))
    end
  end

  defp remember_for_user(conn, locale) do
    case conn.assigns[:current_scope] do
      %{user: %User{} = user} ->
        {:ok, _} = Accounts.update_user_locale(user, locale)
        conn

      _ ->
        conn
    end
  end

  # Back where they were, but only if that is somewhere on this server. An
  # unchecked redirect target here is an open redirect, and a language picker
  # is exactly the sort of harmless-looking link people click from elsewhere.
  defp return_path(conn) do
    case conn.params["return_to"] do
      "/" <> _ = path -> if String.starts_with?(path, "//"), do: "/", else: path
      _ -> "/"
    end
  end
end
