defmodule AbuubaWeb.FeedControllerTest do
  @moduledoc """
  The two RSS feeds, and who may read them.

  `/tags/:tag/feed.rss` is the hashtag timeline in another format, so it
  answers to the same setting as the page: an admin who closed the timelines
  to strangers closed this too. It did not, which made the feed a way to read
  what the page refused to show.

  `/@user/feed.rss` is deliberately different. A profile is not a timeline and
  is not governed by that setting, so the feed of somebody's own public posts
  stays available exactly as their profile does.
  """

  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Settings

  setup do
    on_exit(fn -> Settings.put("timeline_access", "public") end)

    author = account_fixture()
    status = status_fixture(%{account_id: author.id, text: "tagged post #beekeeping"})

    %{author: author, status: status}
  end

  describe "the hashtag feed" do
    test "carries the posts when the timelines are open", %{conn: conn} do
      Settings.put("timeline_access", "public")

      body = conn |> get(~p"/tags/beekeeping/feed.rss") |> response(200)

      assert body =~ "beekeeping"
      assert body =~ "tagged post"
    end

    test "and carries none of them when they are closed to strangers", %{conn: conn} do
      # The page at /tags/beekeeping shows a stranger nothing in this state.
      # The feed is the same timeline with a different content type.
      Settings.put("timeline_access", "authenticated")

      body = conn |> get(~p"/tags/beekeeping/feed.rss") |> response(200)

      refute body =~ "tagged post"
    end

    test "nor when they are off altogether", %{conn: conn} do
      Settings.put("timeline_access", "disabled")

      body = conn |> get(~p"/tags/beekeeping/feed.rss") |> response(200)

      refute body =~ "tagged post"
    end
  end

  describe "an account's feed" do
    test "is a profile rather than a timeline, and stays readable", %{
      conn: conn,
      author: author
    } do
      # Deliberate: `timeline_access` governs this server's timelines, and a
      # profile is not one. Somebody's public posts are as readable as the
      # profile page they sit on.
      Settings.put("timeline_access", "authenticated")

      body = conn |> get(~p"/@#{author.username}/feed.rss") |> response(200)

      assert body =~ "tagged post"
    end
  end
end
