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

  describe "what the charts count" do
    test "one number per day, and a total that is their sum" do
      author = account_fixture()
      today = Date.utc_today()

      for _ <- 1..3, do: status_fixture(%{account_id: author.id, local: true})

      assert {:ok, [%{key: "new_statuses", total: total, data: data}]} =
               Metrics.measure(["new_statuses"], Date.add(today, -6), today)

      assert length(data) == 7
      assert Enum.map(data, & &1.date) == Enum.to_list(Date.range(Date.add(today, -6), today))

      # The total was a second pass over the same days, so it could disagree
      # with the series it sits above. It is their sum now, and cannot.
      assert total == "3"
      assert total == data |> Enum.map(&String.to_integer(&1.value)) |> Enum.sum() |> to_string()
      assert Enum.find(data, &(&1.date == today)).value == "3"
    end

    test "a day nobody posted is a zero rather than a gap" do
      today = Date.utc_today()

      assert {:ok, [%{data: data}]} =
               Metrics.measure(["new_statuses"], Date.add(today, -2), today)

      assert Enum.map(data, & &1.value) |> Enum.all?(&is_binary/1)
      assert Enum.find(data, &(&1.date == Date.add(today, -2))).value == "0"
    end

    test "active users counts people, not posts" do
      author = account_fixture()
      today = Date.utc_today()

      for _ <- 1..4, do: status_fixture(%{account_id: author.id, local: true})

      assert {:ok, [%{total: total}]} =
               Metrics.measure(["active_users"], Date.add(today, -1), today)

      assert total == "1", "four posts from one person is one active person"
    end

    test "retention asks for weeks and gets weeks" do
      today = Date.utc_today()

      rows = Metrics.retention(Date.add(today, -84), today, "week")

      # `"week"` had no clause and fell through to a day, so this answered with
      # eighty-five one-day cohorts labelled as weeks.
      assert length(rows) <= 14, "eighty-five daily cohorts is not a weekly chart"

      assert [%{period: first}, %{period: second} | _] = rows
      assert Date.diff(second, first) == 7
      assert Enum.all?(rows, &(length(&1.data) == length(rows)))
    end

    test "somebody who posted twice in a week is one person still here" do
      today = Date.utc_today()
      account = account_fixture()
      user_fixture(%{account_id: account.id})

      for _ <- 1..2, do: status_fixture(%{account_id: account.id, local: true})

      rows = Metrics.retention(Date.add(today, -84), today, "week")
      last = List.last(rows)

      assert last.total >= 1

      assert Enum.all?(last.data, &(String.to_float(&1.rate) <= 1.0)),
             "counting posts rather than people puts the rate over 100%"
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
