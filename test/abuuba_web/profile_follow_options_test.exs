defmodule AbuubaWeb.ProfileFollowOptionsTest do
  @moduledoc """
  The settings that ride on a follow, from the profile of the person followed:
  their boosts, and which languages of theirs to read.

  The bell — "tell me when they post" — arrived with #216, once there was a
  notification behind it. Until then the column existed and nothing read it,
  and a switch that does nothing is worse than no switch.
  """

  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Relationships

  setup do
    viewer = account_fixture()

    user =
      user_fixture(%{
        account_id: viewer.id,
        approved: true,
        confirmed_at: DateTime.utc_now()
      })

    subject = account_fixture()

    %{viewer: viewer, user: user, subject: subject}
  end

  defp sign_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  defp follow_of(viewer, subject), do: Relationships.get_follow(viewer, subject)

  describe "the controls" do
    test "are not offered to somebody who does not follow", %{conn: conn, user: user, subject: s} do
      {:ok, _live, html} = live(sign_in(conn, user), ~p"/@#{s.username}")

      refute html =~ "follow-options"
    end

    test "appear once they do", %{conn: conn, user: user, viewer: viewer, subject: s} do
      {:ok, _follow} = Relationships.follow(viewer, s)

      {:ok, _live, html} = live(sign_in(conn, user), ~p"/@#{s.username}")

      assert html =~ "follow-options"
    end

    test "are never offered on your own profile", %{conn: conn, user: user, viewer: viewer} do
      {:ok, _live, html} = live(sign_in(conn, user), ~p"/@#{viewer.username}")

      refute html =~ "follow-options"
    end
  end

  describe "boosts" do
    setup %{viewer: viewer, subject: subject} do
      {:ok, _follow} = Relationships.follow(viewer, subject)

      :ok
    end

    test "can be turned off and on again", %{conn: conn, user: user, viewer: v, subject: s} do
      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{s.username}")

      live |> element("#follow-options button[phx-click='toggle_boosts']") |> render_click()

      refute follow_of(v, s).show_reblogs

      live |> element("#follow-options button[phx-click='toggle_boosts']") |> render_click()

      assert follow_of(v, s).show_reblogs
    end
  end

  describe "being told about new posts" do
    setup %{viewer: viewer, subject: subject} do
      {:ok, _follow} = Relationships.follow(viewer, subject)

      :ok
    end

    test "is off to begin with and can be turned on", %{
      conn: conn,
      user: user,
      viewer: v,
      subject: s
    } do
      refute follow_of(v, s).notify

      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{s.username}")

      live |> element("#follow-options button[phx-click='toggle_notify']") |> render_click()

      assert follow_of(v, s).notify

      live |> element("#follow-options button[phx-click='toggle_notify']") |> render_click()

      refute follow_of(v, s).notify
    end
  end

  describe "languages" do
    setup %{viewer: viewer, subject: subject} do
      {:ok, _follow} = Relationships.follow(viewer, subject)

      status_fixture(%{account_id: subject.id, language: "de", text: "hallo"})
      status_fixture(%{account_id: subject.id, language: "en", text: "hello"})

      :ok
    end

    test "offers the ones that account actually posts in", %{conn: conn, user: user, subject: s} do
      {:ok, _live, html} = live(sign_in(conn, user), ~p"/@#{s.username}")

      assert html =~ ~s(value="de")
      assert html =~ ~s(value="en")
    end

    test "narrowing to one keeps it", %{conn: conn, user: user, viewer: v, subject: s} do
      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{s.username}")

      live
      |> form("#follow-options form", follow: %{languages: ["de"]})
      |> render_submit()

      assert follow_of(v, s).languages == ["de"]
    end

    test "choosing none means all of them, not none of them", %{
      conn: conn,
      user: user,
      viewer: v,
      subject: s
    } do
      # An empty list read as "show me nothing" is a timeline that silently
      # goes blank, and the way back is not obvious from the screen.
      {:ok, _follow} = Relationships.follow(v, s, %{languages: ["de"]})

      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{s.username}")

      live |> form("#follow-options form", follow: %{languages: []}) |> render_submit()

      assert follow_of(v, s).languages in [nil, []]
    end
  end

  describe "somebody else's follow" do
    test "cannot be changed by pressing the button on a page you do not own", %{
      conn: conn,
      user: user,
      viewer: viewer,
      subject: subject
    } do
      # The events act on the viewer's own follow of the subject. A stranger's
      # follow of the same person must be untouched by any of it.
      stranger = account_fixture()
      {:ok, _theirs} = Relationships.follow(stranger, subject)
      {:ok, _mine} = Relationships.follow(viewer, subject)

      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{subject.username}")

      live |> element("#follow-options button[phx-click='toggle_boosts']") |> render_click()

      refute follow_of(viewer, subject).show_reblogs
      assert follow_of(stranger, subject).show_reblogs
    end
  end
end
