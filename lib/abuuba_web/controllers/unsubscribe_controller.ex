defmodule AbuubaWeb.UnsubscribeController do
  @moduledoc """
  One click to stop the mail this server sends.

  Every notification email carries this link and a `List-Unsubscribe` header
  pointing at it. A person who wants the mail to stop should be able to make it
  stop from inside the message, without signing in and without finding a
  settings page — somebody who cannot find the button marks the message as spam
  instead, and that costs this server's reputation for everybody on it.

  ## The link is signed rather than looked up

  The token is a signed statement of which account and which kind of mail,
  generated when the message is written and never stored. There is no row to
  leak and no id to guess: a token that was not signed by this server is not a
  token at all.

  ## A GET shows, a POST acts

  Mail clients and security scanners fetch every link in a message before
  anybody reads it. A `GET` that unsubscribed would unsubscribe people who
  never opened the mail, so following the link shows a page with a button.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts.User
  alias Abuuba.Mail.Unsubscribe

  def show(conn, %{"token" => token}) do
    case Unsubscribe.verify(token) do
      {:ok, user_id, kind} -> render_page(conn, token, user_id, kind)
      :error -> invalid(conn)
    end
  end

  def show(conn, _params), do: invalid(conn)

  def update(conn, %{"token" => token}) do
    with {:ok, user_id, kind} <- Unsubscribe.verify(token),
         %User{} = user <- Abuuba.Repo.get(User, user_id) do
      {:ok, _user} = Unsubscribe.apply(user, kind)

      conn
      |> put_flash(:info, gettext("You will not get that kind of email from us again."))
      |> redirect(to: ~p"/")
    else
      _ -> invalid(conn)
    end
  end

  def update(conn, _params), do: invalid(conn)

  defp render_page(conn, token, user_id, kind) do
    case Abuuba.Repo.get(User, user_id) do
      %User{} ->
        render(conn, :show,
          token: token,
          kind: kind,
          page_title: gettext("Stop these emails")
        )

      _ ->
        invalid(conn)
    end
  end

  defp invalid(conn) do
    conn
    |> put_flash(:error, gettext("That link is not valid any more."))
    |> redirect(to: ~p"/")
  end
end
