defmodule AbuubaWeb.FollowRequestsTest do
  @moduledoc """
  Answering the people waiting to follow a locked account.

  Locking is a switch on the privacy page, and everything that switch produces
  was unanswerable from any page: the request arrived as a notification with a
  "hide" button, and the only control in the interface was an accept-all buried
  in the account-migration section and worded for a move.
  `POST /api/v1/follow_requests/:id/authorize` has always answered.

  Its own screen with a counted way in, which is the shape the reference
  implementation settled on: the link is drawn only while somebody is waiting,
  because a permanent nav entry that is empty on all but a handful of servers
  is a permanent reminder of nothing.
  """
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Auth
  alias Abuuba.Relationships

  setup %{conn: conn} do
    account = account_fixture(%{username: "locked"})
    {:ok, account} = Accounts.update_profile(account, %{locked: true})

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))

    %{conn: conn, account: account}
  end

  defp asks(account, username) do
    asker = account_fixture(%{username: username, display_name: "Anna #{username}"})
    {:ok, _} = Relationships.follow_or_request(asker, account)

    asker
  end

  describe "the page" do
    test "lists everybody waiting", %{conn: conn, account: account} do
      one = asks(account, "askerone")
      two = asks(account, "askertwo")

      {:ok, _live, html} = live(conn, ~p"/follow-requests")

      assert html =~ "Anna askerone"
      assert html =~ "@#{one.username}"
      assert html =~ "@#{two.username}"
    end

    test "says so plainly when nobody is", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/follow-requests")

      assert html =~ "Nobody is waiting"
    end

    test "lets one in", %{conn: conn, account: account} do
      asker = asks(account, "askerone")

      {:ok, live, _html} = live(conn, ~p"/follow-requests")

      html =
        live
        |> element("button[phx-click='accept'][phx-value-id='#{asker.id}']")
        |> render_click()

      assert Relationships.following?(asker.id, account.id)
      refute Relationships.get_follow_request(asker, account)
      refute html =~ "Anna askerone"
    end

    test "turns one away, leaving no follow behind", %{conn: conn, account: account} do
      asker = asks(account, "askerone")

      {:ok, live, _html} = live(conn, ~p"/follow-requests")

      live
      |> element("button[phx-click='reject'][phx-value-id='#{asker.id}']")
      |> render_click()

      refute Relationships.following?(asker.id, account.id)
      refute Relationships.get_follow_request(asker, account)
    end

    test "answers only requests that are waiting on the reader", %{conn: conn} do
      # The id comes off the page, so the only thing it may name is a request
      # this account has been asked to answer.
      somebody_else = account_fixture(%{username: "elsewhere"})

      {:ok, other} =
        Accounts.update_profile(account_fixture(%{username: "other"}), %{locked: true})

      {:ok, _} = Relationships.follow_or_request(somebody_else, other)

      {:ok, live, _html} = live(conn, ~p"/follow-requests")
      render_hook(live, "accept", %{"id" => to_string(somebody_else.id)})

      refute Relationships.following?(somebody_else.id, other.id)
      assert Relationships.get_follow_request(somebody_else, other)
    end

    test "is not a page for somebody signed out", %{account: account} do
      asks(account, "askerone")

      assert {:error, {:redirect, %{to: to}}} =
               live(Phoenix.ConnTest.build_conn(), ~p"/follow-requests")

      assert to == ~p"/login"
    end
  end

  describe "the way in" do
    test "is drawn, with a count, while somebody is waiting", %{conn: conn, account: account} do
      asks(account, "askerone")
      asks(account, "askertwo")

      html = conn |> get(~p"/shortcuts") |> html_response(200)

      assert html =~ ~s(href="/follow-requests")
      assert html =~ "Follow requests"
    end

    test "and is not drawn when nobody is", %{conn: conn} do
      # A permanent entry that is empty on all but a handful of servers is a
      # permanent reminder of nothing.
      html = conn |> get(~p"/shortcuts") |> html_response(200)

      refute page(html) =~ "/follow-requests"
    end
  end
end
