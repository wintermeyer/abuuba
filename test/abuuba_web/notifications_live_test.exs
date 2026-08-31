defmodule AbuubaWeb.NotificationsLiveTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Notifications
  alias Abuuba.Streaming

  setup %{conn: conn} do
    reader = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

    %{conn: log_in(conn, user), reader: reader, user: user}
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  describe "the column" do
    test "says something useful when there is nothing", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/notifications")

      assert html =~ "Nothing has happened yet"
    end

    test "shows a mention with the words that were said", %{conn: conn} do
      sender = account_fixture(%{username: "bob", display_name: "Bob"})
      # The post is what tells her: `Statuses.link_text/1` records the mention
      # and notifies, which is the path a real mention takes.
      status_fixture(%{account_id: sender.id, text: "hello @alice"})

      {:ok, _live, html} = live(conn, ~p"/notifications")

      assert html =~ "Bob"
      assert html =~ "hello"
      assert html =~ ~s(class="mention")
      assert html =~ "mentioned you"
    end

    test "shows a follow without pretending there is a post", %{conn: conn, reader: reader} do
      sender = account_fixture(%{username: "bob", display_name: "Bob"})
      {:ok, _} = Notifications.notify(reader, sender, "follow")

      {:ok, _live, html} = live(conn, ~p"/notifications")

      assert html =~ "followed you"
    end
  end

  describe "grouping" do
    test "puts everybody who boosted one post on one line", %{conn: conn, reader: reader} do
      status = status_fixture(%{account_id: reader.id, text: "the popular one"})

      for _ <- 1..12 do
        Notifications.notify(reader, account_fixture(), "reblog", status_id: status.id)
      end

      {:ok, _live, html} = live(conn, ~p"/notifications")

      assert html =~ "12 people boosted"
      assert html =~ "the popular one"
    end

    test "names one person rather than counting them", %{conn: conn, reader: reader} do
      status = status_fixture(%{account_id: reader.id})
      sender = account_fixture(%{username: "bob", display_name: "Bob"})
      {:ok, _} = Notifications.notify(reader, sender, "reblog", status_id: status.id)

      {:ok, _live, html} = live(conn, ~p"/notifications")

      assert html =~ "Bob boosted"
      refute html =~ "1 people"
    end

    test "keeps boosts of different posts apart", %{conn: conn, reader: reader} do
      one = status_fixture(%{account_id: reader.id, text: "the first"})
      two = status_fixture(%{account_id: reader.id, text: "the second"})

      Notifications.notify(reader, account_fixture(), "reblog", status_id: one.id)
      Notifications.notify(reader, account_fixture(), "reblog", status_id: two.id)

      {:ok, _live, html} = live(conn, ~p"/notifications")

      assert html =~ "the first"
      assert html =~ "the second"
    end
  end

  describe "the filter bar" do
    setup %{reader: reader} do
      sender = account_fixture(%{username: "bob"})
      status_fixture(%{account_id: sender.id, text: "a mention of you, @alice"})

      {:ok, _} = Notifications.notify(reader, account_fixture(), "follow")

      :ok
    end

    test "shows everything by default", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/notifications")

      assert html =~ "a mention of you"
      assert html =~ "followed you"
    end

    test "mentions narrows to what was said to you", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/notifications/mentions")

      assert html =~ "a mention of you"
      refute html =~ "followed you"
    end

    test "the filter in the address is the one marked current", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/notifications/mentions")

      assert html =~ ~s(aria-current="page")
    end

    test "the quick filter shows what its label says, whatever else is ticked", %{conn: conn} do
      # Clicking a tab called Mentions and getting an empty page because of a
      # checkbox set weeks ago is a trap, not a filter.
      {:ok, live, _html} = live(conn, ~p"/notifications")
      live |> form("#notification-types", %{"types" => ["follow"]}) |> render_change()

      {:ok, _live, html} = live(conn, ~p"/notifications/mentions")

      assert html =~ "a mention of you"
    end

    test "a per-type filter narrows further", %{conn: conn} do
      # The quick filter covers what most people want; this is for somebody who
      # wants only boosts and has said so.
      {:ok, live, _html} = live(conn, ~p"/notifications")

      html =
        live
        |> form("#notification-types", %{"types" => ["follow"]})
        |> render_change()

      assert html =~ "followed you"
      refute html =~ "a mention of you"
    end

    test "the per-type filter is remembered for next time", %{conn: conn, user: user} do
      {:ok, live, _html} = live(conn, ~p"/notifications")

      live |> form("#notification-types", %{"types" => ["follow"]}) |> render_change()

      assert Abuuba.Repo.get(Abuuba.Accounts.User, user.id).settings["notification_types"] == [
               "follow"
             ]
    end
  end

  describe "as things happen" do
    test "a new one arrives without a reload", %{conn: conn, reader: reader} do
      {:ok, live, _html} = live(conn, ~p"/notifications")

      sender = account_fixture(%{username: "bob", display_name: "Bob"})
      {:ok, notification} = Notifications.notify(reader, sender, "follow")
      Streaming.publish_notification(notification)

      assert render(live) =~ "followed you"
    end

    test "a burst of them is one redraw, not one each", %{conn: conn, reader: reader} do
      # `Streaming.publish_notification/1` broadcasts once per row, and one
      # thing happening is often several rows -- twelve people boosting a post
      # is the moduledoc's own example. Each arrival used to reload the page:
      # seventeen queries, twelve times, to end up drawing one group.
      Application.put_env(:abuuba, :notifications_coalesce_ms, 80)
      on_exit(fn -> Application.put_env(:abuuba, :notifications_coalesce_ms, 0) end)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      post = status_fixture(%{account_id: reader.id, text: "boosted a lot"})

      counter = count_queries()

      for _ <- 1..12 do
        sender = account_fixture()
        {:ok, notification} = Notifications.notify(reader, sender, "reblog", status_id: post.id)
        Streaming.publish_notification(notification)
      end

      # Nothing reloaded yet: the window is still open.
      during = Agent.get(counter, & &1)

      Process.sleep(150)
      html = render(live)

      after_window = Agent.get(counter, & &1) - during

      assert after_window > 0, "the coalesced reload never happened"

      assert after_window < during / 2,
             "one redraw should cost less than the twelve writes that triggered it"

      assert html =~ "boosted"
    end

    defp count_queries do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      handler = "notif-#{System.unique_integer([:positive])}"

      on_exit(fn -> :telemetry.detach(handler) end)

      :telemetry.attach(
        handler,
        [:abuuba, :repo, :query],
        fn _event, _measure, _meta, _config -> Agent.update(counter, &(&1 + 1)) end,
        nil
      )

      counter
    end

    test "somebody else's does not", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/notifications")

      stranger = account_fixture()
      {:ok, notification} = Notifications.notify(stranger, account_fixture(), "follow")
      Streaming.publish_notification(notification)

      refute render(live) =~ "followed you"
    end
  end

  describe "the unread badge" do
    test "counts what is newer than where the reader got to", %{conn: conn, reader: reader} do
      for _ <- 1..3, do: Notifications.notify(reader, account_fixture(), "follow")

      {:ok, _live, html} = live(conn, ~p"/notifications")

      assert html =~ "3"
    end

    test "opening the column marks them read", %{conn: conn, reader: reader} do
      # Otherwise the badge says three forever and stops meaning anything.
      for _ <- 1..3, do: Notifications.notify(reader, account_fixture(), "follow")

      {:ok, live, _html} = live(conn, ~p"/notifications")
      live |> element("button[phx-click='mark_read']") |> render_click()

      assert Notifications.unread_count(reader, marker(reader)) == 0
    end
  end

  describe "the badge in the navigation" do
    test "is visible from another page", %{conn: conn, reader: reader} do
      # A count that only appears once you are already looking at the column is
      # a count nobody needed.
      for _ <- 1..2, do: Notifications.notify(reader, account_fixture(), "follow")

      {:ok, _live, html} = live(conn, ~p"/home")

      assert html =~ "badge--notifications"
      assert html =~ "2"
    end

    test "is absent when there is nothing new", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/home")

      refute html =~ "badge--notifications"
    end
  end

  describe "clearing" do
    test "one can be dismissed", %{conn: conn, reader: reader} do
      {:ok, notification} = Notifications.notify(reader, account_fixture(), "follow")

      {:ok, live, _html} = live(conn, ~p"/notifications")

      live
      |> element("button[phx-value-group='#{notification.group_key}'][phx-click='dismiss']")
      |> render_click()

      assert Notifications.list(reader) == []
    end

    test "all of them can be", %{conn: conn, reader: reader} do
      for _ <- 1..3, do: Notifications.notify(reader, account_fixture(), "follow")

      {:ok, live, _html} = live(conn, ~p"/notifications")
      live |> element("button[phx-click='clear_all']") |> render_click()

      assert Notifications.list(reader) == []
    end
  end

  describe "the requests inbox" do
    setup %{reader: reader} do
      {:ok, _} = Notifications.put_policy(reader, %{"for_not_following" => "filter"})

      stranger = account_fixture(%{username: "carol", display_name: "Carol"})
      status = status_fixture(%{account_id: stranger.id, text: "hello stranger"})
      {:ok, _} = Notifications.notify(reader, stranger, "mention", status_id: status.id)

      %{stranger: stranger}
    end

    test "is shown on the page rather than hidden behind a setting", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/notifications")

      assert html =~ "Carol"
      assert html =~ "waiting"
    end

    test "accepting moves what was filed and stops filing more", %{
      conn: conn,
      reader: reader,
      stranger: stranger
    } do
      {:ok, live, _html} = live(conn, ~p"/notifications")

      live
      |> element("button[phx-value-account='#{stranger.id}'][phx-click='accept_request']")
      |> render_click()

      assert Notifications.requests(reader) == []
      assert length(Notifications.list(reader)) == 1
    end

    test "dismissing hides the request and keeps them filtered", %{
      conn: conn,
      reader: reader,
      stranger: stranger
    } do
      {:ok, live, _html} = live(conn, ~p"/notifications")

      live
      |> element("button[phx-value-account='#{stranger.id}'][phx-click='dismiss_request']")
      |> render_click()

      assert Notifications.requests(reader) == []
      assert Notifications.list(reader) == []
    end

    test "will not accept somebody nobody filed", %{conn: conn, reader: reader} do
      {:ok, live, _html} = live(conn, ~p"/notifications")

      render_click(live, "accept_request", %{"account" => "999999999"})

      assert length(Notifications.requests(reader)) == 1
    end
  end

  defp marker(reader) do
    case Abuuba.Timelines.markers(reader, ["notifications"]) do
      %{"notifications" => marker} -> marker.last_read_id
      _ -> nil
    end
  end

  describe "the notifications a moderator or the server sends" do
    test "a moderation warning says so, and does not name who acted", %{
      conn: conn,
      reader: reader
    } do
      # The one notification somebody most needs to understand, and it read
      # "Something happened involving <moderator>" -- which says nothing, and
      # says it about a person whose name is not the reader's business.
      moderator = account_fixture(%{username: "mod", display_name: "Mod"})

      {:ok, _notification} = Notifications.notify(reader, moderator, "moderation_warning")

      {:ok, _live, html} = live(conn, ~p"/notifications")

      assert html =~ "moderation"
      refute html =~ "Something happened"
      refute page(html) =~ "Mod"
    end

    test "severed relationships say where the follows went", %{conn: conn, reader: reader} do
      # How somebody finds out their follows were cut because this server
      # blocked a domain. "Something happened" is the wrong answer to "where
      # did all my follows go".
      other = account_fixture()

      {:ok, _notification} = Notifications.notify(reader, other, "severed_relationships")

      {:ok, _live, html} = live(conn, ~p"/notifications")

      assert html =~ "follow"
      refute html =~ "Something happened"
    end

    test "and the year in review says what it is", %{conn: conn, reader: reader} do
      {:ok, _notification} = Notifications.notify(reader, reader, "annual_report")

      {:ok, _live, html} = live(conn, ~p"/notifications")

      refute html =~ "Something happened"
    end
  end
end
