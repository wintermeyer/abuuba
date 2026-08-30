defmodule AbuubaWeb.AvatarFallbackTest do
  @moduledoc """
  What is drawn where somebody has not set a picture.

  `AbuubaWeb.StatusComponent` drew `<img src={...["avatar"]}>` unguarded, and an
  account with no avatar has an empty string there. An `<img>` with an empty
  `src` is a broken image in every browser, so every post by anybody who had
  not uploaded a picture carried a broken-image glyph -- on the timeline, on
  explore, in a thread, in the notifications, everywhere the component is used,
  which is everywhere a post appears. A newly registered account is exactly
  that account.

  `AbuubaWeb.ProfileLive` guards the same call in three places, which is what
  made it invisible: the screen somebody looks at while testing was the one
  that had been fixed.

  The element stays either way. It is `size-10 shrink-0`, and dropping it moves
  the text of every post by somebody without a picture ten units to the left.
  """
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth

  setup %{conn: conn} do
    reader = account_fixture(%{username: "reader"})

    user =
      user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

    bare = account_fixture(%{username: "bare", display_name: "No Picture"})
    status_fixture(%{account_id: bare.id, text: "a post from somebody with no avatar"})

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))

    %{conn: conn, bare: bare}
  end

  test "no post anywhere carries an image with nothing to load", %{conn: conn, bare: bare} do
    for path <- [~p"/explore", ~p"/@#{bare.username}", ~p"/home"] do
      {:ok, _live, html} = live(conn, path)

      refute html =~ ~s(<img src=""),
             "#{path} drew an image with an empty src, which is a broken image"
    end
  end

  test "and the row still lines up with the ones that have a picture", %{conn: conn} do
    # Dropping the element instead would move the text of every post by
    # somebody without a picture, which is most of them on a new server.
    {:ok, _live, html} = live(conn, ~p"/explore")

    assert html =~ "size-10 shrink-0 rounded"
  end

  test "somebody who has one still gets it", %{conn: conn, bare: bare} do
    # The control: a fix that drew a placeholder for everybody would satisfy
    # the assertion above and lose every avatar on the server.
    dressed = account_fixture(%{username: "dressed"})

    {:ok, _} =
      dressed
      |> Ecto.Changeset.change(%{
        avatar_file_name: "portrait.png",
        avatar_content_type: "image/png"
      })
      |> Abuuba.Repo.update()

    status_fixture(%{account_id: dressed.id, text: "a post from somebody with an avatar"})

    {:ok, _live, html} = live(conn, ~p"/explore")

    assert html =~ "portrait.png"
    assert bare
  end
end
