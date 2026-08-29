defmodule AbuubaWeb.BrowserLanguageTest do
  @moduledoc """
  What language a page comes back in for somebody who has not chosen one.

  The plug on the request path reads `Accept-Language` and the hook that runs
  when a LiveView mounts did not, so it resolved from the user and the session
  alone and fell back to English. Nearly every page here is a LiveView, so a
  German browser arriving at this server was answered in English however
  plainly it had asked -- and German is the second language this project
  ships, not an afterthought.
  """
  use AbuubaWeb.ConnCase, async: false

  describe "a browser that asks for German" do
    test "is answered in German on a plain page", %{conn: conn} do
      html =
        conn
        |> put_req_header("accept-language", "de")
        |> get(~p"/about")
        |> html_response(200)

      assert html =~ "Registrierung"
      refute html =~ "Signing up"
    end

    test "and on one it has to sign in for", %{conn: conn} do
      # The sign-in page is a LiveView too, and is the first thing a visitor
      # from a German-speaking browser is likely to see.
      html =
        conn
        |> put_req_header("accept-language", "de")
        |> get(~p"/login")
        |> html_response(200)

      assert html =~ "Anmelden" or html =~ "Passwort"
    end

    test "and a tagged locale still finds the language", %{conn: conn} do
      html =
        conn
        |> put_req_header("accept-language", "de-AT,de;q=0.9")
        |> get(~p"/about")
        |> html_response(200)

      assert html =~ "Registrierung"
    end

    test "while a browser asking for English gets English", %{conn: conn} do
      # The control. An assertion that German appears would pass just as well
      # if every page were German whatever was asked for.
      html =
        conn
        |> put_req_header("accept-language", "en")
        |> get(~p"/about")
        |> html_response(200)

      assert html =~ "Signing up"
      refute html =~ "Registrierung"
    end
  end
end
