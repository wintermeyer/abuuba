defmodule AbuubaWeb.NotificationSettingsTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Notifications
  alias Abuuba.Notifications.Policy

  setup %{conn: conn} do
    reader = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

    %{conn: log_in(conn, user), reader: reader}
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  describe "the page" do
    test "is its own page rather than something behind a cog", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/notifications")

      assert html =~ "Who can reach you"
    end

    test "offers all three decisions for every axis", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/notifications")

      for axis <- Policy.axes() do
        assert html =~ ~s(name="policy[#{axis}]")
      end

      assert html =~ "Accept"
      assert html =~ "Filter"
      assert html =~ "Ignore"
    end

    test "says plainly that ignoring throws things away", %{conn: conn} do
      # The difference between filtering and ignoring is that one is
      # recoverable and the other is not, and somebody choosing between them
      # has to be told which is which.
      {:ok, _live, html} = live(conn, ~p"/settings/notifications")

      assert html =~ "cannot be recovered"
    end

    test "shows what is currently set", %{conn: conn, reader: reader} do
      {:ok, _} = Notifications.put_policy(reader, %{"for_bots" => "drop"})

      {:ok, _live, html} = live(conn, ~p"/settings/notifications")

      assert html =~ ~s(value="drop" checked)
    end
  end

  describe "changing it" do
    test "records a decision", %{conn: conn, reader: reader} do
      {:ok, live, _html} = live(conn, ~p"/settings/notifications")

      live
      |> form("#notification-policy", %{"policy" => %{"for_not_following" => "filter"}})
      |> render_submit()

      assert Notifications.policy(reader).for_not_following == "filter"
    end

    test "keeps the axes it was not asked about", %{conn: conn, reader: reader} do
      {:ok, _} = Notifications.put_policy(reader, %{"for_bots" => "drop"})

      {:ok, live, _html} = live(conn, ~p"/settings/notifications")

      live
      |> form("#notification-policy", %{"policy" => %{"for_not_following" => "filter"}})
      |> render_submit()

      assert Notifications.policy(reader).for_bots == "drop"
    end

    test "refuses a decision nobody defined", %{conn: conn, reader: reader} do
      {:ok, live, _html} = live(conn, ~p"/settings/notifications")

      html = render_submit(live, "save", %{"policy" => %{"for_bots" => "maybe"}})

      assert html =~ "could not be saved"
      assert Notifications.policy(reader).for_bots == "accept"
    end

    test "says so when it worked", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/settings/notifications")

      html =
        live
        |> form("#notification-policy", %{"policy" => %{"for_not_following" => "filter"}})
        |> render_submit()

      assert html =~ "Saved"
    end
  end

  describe "who may see it" do
    test "not somebody who is signed out", %{} do
      conn = Phoenix.ConnTest.build_conn()

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/settings/notifications")
    end
  end
end
