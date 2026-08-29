defmodule AbuubaWeb.PostActionsTest do
  @moduledoc """
  The post action bar, on every screen that draws it.

  Written as one list of screens rather than four test files on purpose. The
  bug being fixed is that four screens drew the buttons and implemented none of
  them, which no per-screen test would have caught because nobody wrote one —
  so the guard has to be the enumeration, and a fifth screen that renders posts
  belongs in the list below.
  """

  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Statuses

  setup do
    viewer = account_fixture()

    user =
      user_fixture(%{account_id: viewer.id, approved: true, confirmed_at: DateTime.utc_now()})

    author = account_fixture()

    %{viewer: viewer, user: user, author: author}
  end

  defp sign_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  # Each screen, and what it takes to make a post appear on it.
  defp screens(author) do
    tag = "abuubatest#{System.unique_integer([:positive])}"

    [
      {"a profile", fn -> status_fixture(%{account_id: author.id, text: "on a profile"}) end,
       fn _status -> "/@#{author.username}" end},
      {"explore", fn -> status_fixture(%{account_id: author.id, text: "on explore"}) end,
       fn _status -> "/explore" end},
      {"a tag page", fn -> status_fixture(%{account_id: author.id, text: "about ##{tag}"}) end,
       fn _status -> "/tags/#{tag}" end},
      {"search", fn -> status_fixture(%{account_id: author.id, text: "findable#{tag}"}) end,
       fn _status -> "/search?q=findable#{tag}&type=statuses" end},
      {"the home timeline",
       fn ->
         status_fixture(%{account_id: author.id, text: "at home"})
       end, fn _status -> "/home" end},
      {"a post's own page",
       fn -> status_fixture(%{account_id: author.id, text: "on its own"}) end,
       fn status -> "/@#{author.username}/#{status.id}" end}
    ]
  end

  describe "favouriting a post" do
    test "works on every screen that draws the button", %{
      conn: conn,
      user: user,
      viewer: viewer,
      author: author
    } do
      # Home needs the follow for the post to arrive at all.
      {:ok, _follow} = Abuuba.Relationships.follow(viewer, author)

      for {name, make, path} <- screens(author) do
        status = make.()

        {:ok, live, _html} = live(sign_in(conn, user), path.(status))

        live
        |> element("button[phx-click='favourite'][phx-value-id='#{status.id}']")
        |> render_click()

        assert Statuses.favourited?(viewer.id, status.id),
               "favouriting did nothing on #{name}"
      end
    end

    test "and unfavouriting undoes it", %{conn: conn, user: user, viewer: viewer, author: author} do
      status = status_fixture(%{account_id: author.id, text: "on a profile"})
      {:ok, _fav} = Statuses.favourite(viewer, status)

      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{author.username}")

      live
      |> element("button[phx-click='favourite'][phx-value-id='#{status.id}']")
      |> render_click()

      refute Statuses.favourited?(viewer.id, status.id)
    end
  end

  describe "boosting and bookmarking" do
    test "work on a profile too", %{conn: conn, user: user, viewer: viewer, author: author} do
      status = status_fixture(%{account_id: author.id, text: "on a profile"})

      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{author.username}")

      live |> element("button[phx-click='boost'][phx-value-id='#{status.id}']") |> render_click()
      assert Statuses.boosted?(viewer.id, status.id)

      live
      |> element("button[phx-click='bookmark'][phx-value-id='#{status.id}']")
      |> render_click()

      assert Statuses.bookmarked?(viewer.id, status.id)
    end
  end

  describe "somebody signed out" do
    test "is not offered the buttons at all", %{conn: conn, author: author} do
      status = status_fixture(%{account_id: author.id, text: "on a profile"})

      {:ok, _live, html} = live(conn, ~p"/@#{author.username}")

      assert html =~ "on a profile"
      refute html =~ "phx-click=\"favourite\" phx-value-id=\"#{status.id}\""
    end
  end

  describe "replying from a screen with nowhere to type" do
    test "goes to the post, where there is somewhere", %{
      conn: conn,
      user: user,
      author: author
    } do
      # Profile, explore, tag and search have no composer. Opening one there
      # would be a box that appears on some screens and not others; going to
      # the post is the same answer every time.
      status = status_fixture(%{account_id: author.id, text: "on a profile"})

      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{author.username}")

      live |> element("button[phx-click='reply'][phx-value-id='#{status.id}']") |> render_click()

      assert_redirect(live, "/@#{author.username}/#{status.id}")
    end
  end
end
