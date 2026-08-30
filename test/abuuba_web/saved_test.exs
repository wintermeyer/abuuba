defmodule AbuubaWeb.SavedTest do
  @moduledoc """
  The two lists a reader builds by pressing buttons on posts.

  `AbuubaWeb.StatusComponent` draws a bookmark and a favourite on every post on
  every screen, `GET /api/v1/bookmarks` and `/api/v1/favourites` have always
  answered, and there was nowhere in this server's own interface to see either.
  A control that works and leads nowhere is the same shape as one that does not
  work: the reader presses it and never finds out what it did.
  """
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Statuses

  setup %{conn: conn} do
    reader = account_fixture(%{username: "collector"})

    user =
      user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

    author = account_fixture(%{username: "writer"})

    kept = status_fixture(%{account_id: author.id, text: "worth keeping"})
    liked = status_fixture(%{account_id: author.id, text: "worth applauding"})
    ignored = status_fixture(%{account_id: author.id, text: "worth nothing"})

    {:ok, _} = Statuses.bookmark(reader, kept)
    {:ok, _} = Statuses.favourite(reader, liked)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))

    %{conn: conn, reader: reader, kept: kept, liked: liked, ignored: ignored}
  end

  describe "bookmarks" do
    test "shows what was bookmarked and nothing else", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/bookmarks")

      assert html =~ "worth keeping"
      refute html =~ "worth applauding"
      refute html =~ "worth nothing"
    end

    test "and the bar on them works, like on every other screen", %{
      conn: conn,
      reader: reader,
      kept: kept
    } do
      {:ok, live, _html} = live(conn, ~p"/bookmarks")

      live
      |> element("button[phx-click='favourite'][phx-value-id='#{kept.id}']")
      |> render_click()

      assert Statuses.favourited?(reader.id, kept.id)
    end

    test "and unbookmarking takes it off the list it is on", %{
      conn: conn,
      reader: reader,
      kept: kept
    } do
      {:ok, live, _html} = live(conn, ~p"/bookmarks")

      html =
        live
        |> element("button[phx-click='bookmark'][phx-value-id='#{kept.id}']")
        |> render_click()

      refute Statuses.bookmarked?(reader.id, kept.id)
      refute html =~ "worth keeping"
    end
  end

  describe "favourites" do
    test "shows what was favourited and nothing else", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/favourites")

      assert html =~ "worth applauding"
      refute html =~ "worth keeping"
    end

    test "and unfavouriting takes it off the list it is on", %{
      conn: conn,
      reader: reader,
      liked: liked
    } do
      {:ok, live, _html} = live(conn, ~p"/favourites")

      html =
        live
        |> element("button[phx-click='favourite'][phx-value-id='#{liked.id}']")
        |> render_click()

      refute Statuses.favourited?(reader.id, liked.id)
      refute html =~ "worth applauding"
    end
  end

  describe "an empty list" do
    setup %{reader: reader, kept: kept, liked: liked} do
      Statuses.unbookmark(reader, kept)
      Statuses.unfavourite(reader, liked)

      :ok
    end

    test "says what the button that fills it does", %{conn: conn} do
      {:ok, _live, bookmarks} = live(conn, ~p"/bookmarks")
      {:ok, _live, favourites} = live(conn, ~p"/favourites")

      assert bookmarks =~ "Nothing bookmarked yet"
      assert favourites =~ "Nothing favourited yet"
    end
  end

  describe "the way in" do
    test "is on every page, for somebody signed in", %{conn: conn} do
      html = conn |> get(~p"/shortcuts") |> html_response(200)

      assert html =~ ~s(href="/bookmarks")
      assert html =~ ~s(href="/favourites")
    end

    test "and is not offered to a stranger", %{conn: _conn} do
      html = Phoenix.ConnTest.build_conn() |> get(~p"/shortcuts") |> html_response(200)

      refute page(html) =~ "/bookmarks"
      refute page(html) =~ "/favourites"
    end

    test "and neither page answers one", %{conn: _conn} do
      for path <- [~p"/bookmarks", ~p"/favourites"] do
        assert {:error, {:redirect, %{to: to}}} = live(Phoenix.ConnTest.build_conn(), path)
        assert to == ~p"/login"
      end
    end
  end
end
