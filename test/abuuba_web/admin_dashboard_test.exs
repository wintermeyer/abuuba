defmodule AbuubaWeb.AdminDashboardTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Admin.Metrics
  alias Abuuba.Roles

  setup %{conn: conn} do
    %{conn: log_in(conn, staff(["view_dashboard"]))}
  end

  defp staff(permissions) do
    {:ok, role} =
      Roles.create(%{
        name: "Role #{System.unique_integer([:positive])}",
        position: 900,
        permissions: Roles.mask(permissions)
      })

    user =
      user_fixture(%{
        account_id: account_fixture().id,
        approved: true,
        confirmed_at: DateTime.utc_now()
      })

    {:ok, user} = Roles.assign(user, role)

    user
  end

  describe "the dashboard" do
    test "draws the measures in words rather than API keys", %{conn: conn} do
      status_fixture(%{account_id: account_fixture().id, text: "something"})

      {:ok, _live, html} = live(conn, ~p"/admin")

      # The API's keys are for clients; a dashboard is for a person.
      assert html =~ "Posts written here"
      assert html =~ "New accounts"
      refute html =~ "new_statuses"
    end

    test "draws a chart without pulling in a library", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin")

      # An inline SVG, so the page can keep the strict policy everything else
      # here has.
      assert html =~ "<svg"
      assert html =~ "polyline"
    end

    test "labels the chart for somebody who cannot see it", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin")

      assert html =~ ~s(role="img")
      assert html =~ "aria-label"
    end

    test "shows the dimensions and the retention table", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin")

      assert html =~ "Where things come from"
      assert html =~ "Languages people write in"
      assert html =~ "Who stayed"
    end

    test "still shows what needs attention", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin")

      assert html =~ "What needs attention"
    end

    test "renders on a server where nothing has happened", %{conn: conn} do
      # A fresh instance is the case a dashboard is most often first seen in,
      # and dividing by a zero maximum is how a chart breaks there.
      {:ok, _live, html} = live(conn, ~p"/admin")

      assert html =~ "The last thirty days"
    end
  end

  describe "the same numbers over the API" do
    test "are what the dashboard draws", %{conn: conn} do
      status_fixture(%{account_id: account_fixture().id, text: "something"})

      to = Date.utc_today()
      from = Date.add(to, -30)

      {:ok, [series]} = Metrics.measure(["new_statuses"], from, to)

      # One question, one answer: a moderation client and this page should not
      # disagree about how many posts were written.
      {:ok, _live, html} = live(conn, ~p"/admin")
      assert html =~ series.total
    end
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end
end
