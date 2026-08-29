defmodule AbuubaWeb.MuteThreadTest do
  @moduledoc """
  Muting the conversation a post belongs to, from the post.

  The thing being tested is the timeline going quiet, not a row being written:
  a menu item that stores a mute nothing reads would look exactly the same from
  the outside.
  """

  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Relationships
  alias Abuuba.Statuses

  setup do
    reader = account_fixture()

    user =
      user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

    author = account_fixture()
    {:ok, _follow} = Relationships.follow(reader, author)

    %{reader: reader, user: user, author: author}
  end

  defp sign_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  defp in_a_thread(author) do
    root = status_fixture(%{account_id: author.id, text: "the start"})

    # A conversation only exists once there is a conversation: a lone post has
    # no thread to mute, which is a case the menu has to handle rather than
    # offer a control that errors.
    status_fixture(%{account_id: author.id, text: "and on it goes", in_reply_to_id: root.id})
  end

  describe "the menu" do
    test "is not offered to somebody signed out", %{conn: conn, author: author} do
      # On the thread view, which a signed-out reader can open — unlike the
      # home timeline, which is not theirs to see at all.
      status = in_a_thread(author)

      {:ok, _live, html} = live(conn, ~p"/@#{author.username}/#{status.id}")

      assert html =~ "and on it goes"
      refute html =~ "mute_thread"
    end

    test "offers muting on a post that is in a thread", %{conn: conn, user: user, author: a} do
      in_a_thread(a)

      {:ok, _live, html} = live(sign_in(conn, user), ~p"/home")

      assert html =~ "mute_thread"
    end

    test "offers nothing on a post that is not", %{conn: conn, user: user, author: author} do
      status_fixture(%{account_id: author.id, text: "on its own"})

      {:ok, _live, html} = live(sign_in(conn, user), ~p"/home")

      refute html =~ "mute_thread"
    end
  end

  describe "muting" do
    test "takes the thread out of the timeline", %{conn: conn, user: user, reader: r, author: a} do
      status = in_a_thread(a)

      {:ok, live, html} = live(sign_in(conn, user), ~p"/home")
      assert html =~ "and on it goes"

      live
      |> element("button[phx-click='mute_thread'][phx-value-id='#{status.id}']")
      |> render_click()

      assert Statuses.thread_muted?(r, status)

      # The point of the whole thing: a fresh read of the timeline no longer
      # has it.
      {:ok, _live, html} = live(sign_in(conn, user), ~p"/home")
      refute html =~ "and on it goes"
    end

    test "and unmuting puts it back", %{conn: conn, user: user, reader: r, author: a} do
      status = in_a_thread(a)
      {:ok, _mute} = Statuses.mute_thread(r, status)

      # From the thread view, which is where somebody who has just muted a
      # conversation goes looking to undo it.
      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{a.username}/#{status.id}")

      live
      |> element("button[phx-click='unmute_thread'][phx-value-id='#{status.id}']")
      |> render_click()

      refute Statuses.thread_muted?(r, status)

      {:ok, _live, html} = live(sign_in(conn, user), ~p"/home")
      assert html =~ "and on it goes"
    end
  end

  describe "somebody else's mute" do
    test "is not touched by muting your own", %{conn: conn, user: user, reader: r, author: a} do
      status = in_a_thread(a)
      stranger = account_fixture()

      {:ok, live, _html} = live(sign_in(conn, user), ~p"/home")

      live
      |> element("button[phx-click='mute_thread'][phx-value-id='#{status.id}']")
      |> render_click()

      assert Statuses.thread_muted?(r, status)
      refute Statuses.thread_muted?(stranger, status)
    end
  end
end
