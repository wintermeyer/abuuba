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
  alias Abuuba.Notifications
  alias Abuuba.Statuses
  alias AbuubaWeb.PostActions

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

  # Notifications is the sixth screen and was the one nobody had listed: it
  # drew the whole bar and answered none of it, because the source sweep next
  # door had a hand-written list of screens and this was not on it. It takes a
  # notification rather than just a post, so it does not fit `screens/1`.
  defp notification_path(reader, author) do
    status = status_fixture(%{account_id: author.id, text: "boosted at you"})
    {:ok, _notification} = Notifications.notify(reader, author, "reblog", status_id: status.id)

    {status, "/notifications"}
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

  describe "the notifications screen" do
    test "answers the bar it draws", %{conn: conn, user: user, viewer: viewer, author: author} do
      {status, path} = notification_path(viewer, author)

      {:ok, live, _html} = live(sign_in(conn, user), path)

      live
      |> element("button[phx-click='favourite'][phx-value-id='#{status.id}']")
      |> render_click()

      assert Statuses.favourited?(viewer.id, status.id),
             "favouriting did nothing on the notifications screen"
    end

    test "and puts the post back where it keeps it", %{
      conn: conn,
      user: user,
      viewer: viewer,
      author: author
    } do
      {status, path} = notification_path(viewer, author)

      {:ok, live, _html} = live(sign_in(conn, user), path)

      html =
        live
        |> element("button[phx-click='boost'][phx-value-id='#{status.id}']")
        |> render_click()

      assert Statuses.boosted?(viewer.id, status.id)

      # The post lives inside its notification group here rather than in a
      # list, so this is the half that a shared put-back would have got wrong
      # without saying so: the row has to redraw, not vanish.
      assert html =~ "boosted at you"
    end
  end

  # `Abuuba.Statuses.delete_status/1` has always been there, and the only ways
  # to reach it were the Mastodon API and the admin screens: nothing in this
  # server's own interface let somebody take back a post they had written.
  describe "deleting a post of your own" do
    test "works on every screen that draws the button", %{
      conn: conn,
      user: user,
      viewer: viewer
    } do
      # The author is the viewer here, which is the whole point: the button is
      # only drawn on your own posts.
      for {name, make, path} <- screens(viewer) do
        status = make.()

        {:ok, live, _html} = live(sign_in(conn, user), path.(status))

        live
        |> element("button[phx-click='delete'][phx-value-id='#{status.id}']")
        |> render_click()

        assert Statuses.get_status(status.id, viewer) == nil,
               "deleting did nothing on #{name}"
      end
    end

    test "takes the post off the screen it was deleted from", %{
      conn: conn,
      user: user,
      viewer: viewer
    } do
      status = status_fixture(%{account_id: viewer.id, text: "a post to take back"})

      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{viewer.username}")

      html =
        live
        |> element("button[phx-click='delete'][phx-value-id='#{status.id}']")
        |> render_click()

      refute html =~ "a post to take back"
    end

    test "sends you away from the page that was only that post", %{
      conn: conn,
      user: user,
      viewer: viewer
    } do
      status = status_fixture(%{account_id: viewer.id, text: "the only thing here"})

      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{viewer.username}/#{status.id}")

      live
      |> element("button[phx-click='delete'][phx-value-id='#{status.id}']")
      |> render_click()

      assert_redirect(live, ~p"/@#{viewer.username}")
    end
  end

  test "takes the boost of it off the screen as well", %{
    conn: conn,
    user: user,
    viewer: viewer,
    author: author
  } do
    # The row is the boost's, drawn under the booster; the delete answers with
    # the post's own id. Matching only the row's id left the words of a
    # deleted post on screen under a flash saying it was gone.
    mine = status_fixture(%{account_id: viewer.id, text: "boosted and then taken back"})
    {:ok, _boost} = Statuses.boost(author, mine)

    {:ok, live, html} = live(sign_in(conn, user), ~p"/@#{author.username}")
    assert html =~ "boosted and then taken back"

    html =
      live
      |> element("button[phx-click='delete'][phx-value-id='#{mine.id}']")
      |> render_click()

    refute html =~ "boosted and then taken back"
  end

  test "and off the home timeline, which keys that row by the post's own id", %{
    conn: conn,
    user: user,
    viewer: viewer,
    author: author
  } do
    {:ok, _follow} = Abuuba.Relationships.follow(viewer, author)
    mine = status_fixture(%{account_id: viewer.id, text: "boosted onto the timeline"})
    {:ok, _boost} = Statuses.boost(author, mine)

    {:ok, live, html} = live(sign_in(conn, user), ~p"/home")
    assert html =~ "boosted onto the timeline"

    html =
      live
      |> element("button[phx-click='delete'][phx-value-id='#{mine.id}']")
      |> render_click()

    refute html =~ "boosted onto the timeline"
  end

  test "and the notifications screen, which keeps posts inside groups", %{
    conn: conn,
    user: user,
    viewer: viewer,
    author: author
  } do
    # The one screen `screens/1` cannot cover: its posts are not in a list, so
    # it hands `PostActions` its own way of taking one off, and a wrong clause
    # there would be silent.
    mine = status_fixture(%{account_id: viewer.id, text: "favourited then withdrawn"})
    {:ok, _} = Notifications.notify(viewer, author, "favourite", status_id: mine.id)

    {:ok, live, html} = live(sign_in(conn, user), ~p"/notifications")
    assert html =~ "favourited then withdrawn"

    html =
      live
      |> element("button[phx-click='delete'][phx-value-id='#{mine.id}']")
      |> render_click()

    refute html =~ "favourited then withdrawn"
    assert Statuses.get_status(mine.id, viewer) == nil
  end

  test "an id no row could carry is refused rather than fatal", %{conn: conn, user: user} do
    # Every button on the bar comes through the same lookup, and a number too
    # big for the column reached Ecto as a cast error that emptied the page.
    {:ok, live, _html} = live(sign_in(conn, user), ~p"/explore")

    render_hook(live, "delete", %{"id" => "99999999999999999999999999"})

    assert Process.alive?(live.pid)
  end

  describe "somebody else's post" do
    test "is not offered a delete button", %{conn: conn, user: user, author: author} do
      status = status_fixture(%{account_id: author.id, text: "not yours to delete"})

      {:ok, _live, html} = live(sign_in(conn, user), ~p"/@#{author.username}")

      refute html =~ ~s(phx-click="delete")
      assert Statuses.get_status(status.id, author)
    end

    test "and is not deleted by asking for it anyway", %{
      conn: conn,
      user: user,
      viewer: viewer,
      author: author
    } do
      # The button being absent is a drawing decision; this is the one that
      # matters, because the event can be sent without it.
      status = status_fixture(%{account_id: author.id, text: "still not yours"})

      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{author.username}")
      render_hook(live, "delete", %{"id" => to_string(status.id)})

      assert Statuses.get_status(status.id, viewer)
    end
  end

  # A screen with no composer answers reply and edit by sending you to the
  # post's own page, which has one -- and sent you there with the box closed,
  # so the button you pressed did nothing once you arrived and you had to
  # press the same button again. Edit was the worse half: an empty box on the
  # post you meant to change reads as the post having been lost.
  describe "reply and edit from a screen with no composer" do
    test "arrive with the box open on the post you pressed", %{
      conn: conn,
      user: user,
      viewer: viewer,
      author: author
    } do
      status = status_fixture(%{account_id: author.id, text: "worth answering"})

      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{author.username}")

      live |> element("button[phx-click='reply'][phx-value-id='#{status.id}']") |> render_click()

      {path, _flash} = assert_redirect(live)
      {:ok, arrived, _html} = live(sign_in(conn, user), path)

      # Rendered again rather than read off the mount: the composer is a
      # component and is told what to open through `send_update/2`, which lands
      # in the message after the one that mounted it.
      assert render(arrived) =~ "Replying to"
      refute viewer.id == author.id
    end

    test "and editing your own arrives with what you wrote in it", %{
      conn: conn,
      user: user,
      viewer: viewer
    } do
      status = status_fixture(%{account_id: viewer.id, text: "the words to change"})

      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{viewer.username}")

      live |> element("button[phx-click='edit'][phx-value-id='#{status.id}']") |> render_click()

      {path, _flash} = assert_redirect(live)
      {:ok, arrived, _html} = live(sign_in(conn, user), path)
      html = render(arrived)

      assert html =~ "the words to change"
      assert html =~ "Editing a post"
      assert html =~ "Save changes"
    end
  end

  # `PostActions.composers/0` says what a screen with no composer may ask a
  # post's page to open, and its docstring claims the two ends cannot drift.
  # This is what makes that true: without it the emitter and the matcher are
  # two lists of string literals in two files.
  describe "the compose intents" do
    test "are all answered by the page they are sent to", %{
      conn: conn,
      user: user,
      viewer: viewer
    } do
      status = status_fixture(%{account_id: viewer.id, text: "something to act on"})
      opened = %{"reply" => "Replying to", "edit" => "Editing a post"}

      for intent <- PostActions.composers() do
        path = PostActions.page_of(viewer, status.id, compose: intent)

        assert path =~ "compose=#{intent}"

        {:ok, live, _html} = live(sign_in(conn, user), path)

        assert render(live) =~ Map.fetch!(opened, intent),
               "the page does not answer compose=#{intent}"
      end
    end

    test "and anything else is dropped rather than carried", %{viewer: viewer} do
      status = status_fixture(%{account_id: viewer.id, text: "not for this"})

      for junk <- ["", "boost", "<script>x</script>", "reply "] do
        refute PostActions.page_of(viewer, status.id, compose: junk) =~ "compose"
      end
    end

    test "and edit is refused on a post that is not yours", %{
      conn: conn,
      user: user,
      author: author
    } do
      # The address carries the same request the button does, so it is refused
      # in the same place.
      status = status_fixture(%{account_id: author.id, text: "not yours to change"})

      {:ok, live, _html} =
        live(sign_in(conn, user), "/@#{author.username}/#{status.id}?compose=edit")

      html = render(live)

      refute html =~ "Editing a post"
      refute html =~ "Save changes"
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

      assert_redirect(live, "/@#{author.username}/#{status.id}?compose=reply")
    end
  end
end
