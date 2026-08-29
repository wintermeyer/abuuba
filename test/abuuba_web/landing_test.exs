defmodule AbuubaWeb.LandingTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth

  setup %{conn: conn} do
    author = account_fixture(%{username: "bob", display_name: "Bob"})

    %{conn: conn, author: author}
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  describe "the front page" do
    test "says what this server is", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ Abuuba.Instance.software_name()
      assert html =~ "fediverse"
    end

    test "shows what is being said here", %{conn: conn, author: author} do
      # A landing page with no people on it is a landing page nobody can judge.
      status_fixture(%{account_id: author.id, text: "a public post from here"})

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "a public post from here"
    end

    test "shows nothing private", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "for followers", visibility: :private})

      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ "for followers"
    end

    test "offers the way in", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(href="/register")
      assert html =~ ~s(href="/login")
      assert html =~ ~s(href="/explore")
    end

    test "says whether anybody can join", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Registration"
    end

    test "sends a signed-in reader to their own timeline", %{conn: conn, author: author} do
      # Somebody with a home timeline has no use for the sales pitch.
      user =
        user_fixture(%{account_id: author.id, approved: true, confirmed_at: DateTime.utc_now()})

      conn = conn |> log_in(user) |> get(~p"/")

      assert redirected_to(conn) == ~p"/home"
    end
  end
end
