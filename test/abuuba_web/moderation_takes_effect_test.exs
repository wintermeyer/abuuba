defmodule AbuubaWeb.ModerationTakesEffectTest do
  @moduledoc """
  What a moderator's decision actually stops.

  The API has always refused a suspended account: `RequireUser` answers 403 and
  says in a comment why "we could not check" has to mean no. The pages of this
  server's own interface ask only whether somebody is signed in. So the
  strongest action a moderator has closed the API and left the website open --
  a suspended person could sign in afresh and go on posting through the
  compose box, and the moderator had no way to tell.

  Disabling had the narrower version of the same hole: it is checked when
  somebody signs in and nowhere afterwards, and nothing ended the sessions
  they already had, so it took effect whenever they next happened to sign out.

  `Abuuba.Admin.force_password_reset/2` has ended sessions and revoked tokens
  since it was written, so the machinery was there; suspend and disable simply
  did not use it.
  """
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures
  import Phoenix.LiveViewTest

  alias Abuuba.Accounts.Auth
  alias Abuuba.Moderation.Actions
  alias Abuuba.Statuses

  @password "correct horse battery"

  setup do
    :ok = Abuuba.Settings.put_registration_mode(:open)

    # Registered and confirmed the way a person is, so the password really
    # works: a fixture that never set one would make the sign-in tests below
    # pass for the wrong reason.
    {:ok, %{user: user}} =
      Auth.register(
        %{"username" => "member", "email" => "member@example.com", "password" => @password},
        rules_required: false
      )

    {:ok, token} = Auth.create_confirmation_token(user)
    {:ok, user} = Auth.confirm_user(token)
    {:ok, user} = Auth.approve_user(user)

    %{
      account: Abuuba.Accounts.get_account(user.account_id),
      user: user,
      moderator: account_fixture(%{username: "mod"})
    }
  end

  defp with_session(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  defp sign_in(conn, user) do
    post(conn, ~p"/login", %{
      "user" => %{"email" => user.email, "password" => @password}
    })
  end

  describe "an ordinary account" do
    test "signs in and reads a page that needs one", %{conn: conn, user: user} do
      # The control. Every assertion below is that something is refused, which
      # a server refusing everybody would satisfy just as well.
      assert redirected_to(sign_in(conn, user)) != ~p"/login"

      assert conn |> with_session(user) |> get(~p"/settings") |> html_response(200)
    end
  end

  describe "a suspended account" do
    setup %{account: account, moderator: moderator} do
      {:ok, _} = Actions.take(moderator, account, "suspend")
      :ok
    end

    test "cannot sign in", %{conn: conn, user: user} do
      conn = sign_in(conn, user)

      assert redirected_to(conn) == ~p"/login" or html_response(conn, 200)
      refute get_session(conn, :user_token), "a suspended account was handed a session"
    end

    test "and the session it already had stops working", %{conn: conn, user: user} do
      session = with_session(conn, user)

      assert redirected_to(get(session, ~p"/settings")) == ~p"/login"
    end

    test "and the credentials it was holding are gone, not merely refused", %{user: user} do
      # Every request checks, so a leftover session is refused either way. They
      # go anyway: a session token and an app token are live credentials, and
      # revoking the app tokens is also what closes a streaming connection,
      # which authenticates once and would otherwise keep delivering.
      assert Abuuba.Repo.all(Abuuba.Accounts.UserToken) |> Enum.filter(&(&1.user_id == user.id)) ==
               []

      live =
        Abuuba.Repo.all(Abuuba.OAuth.AccessToken)
        |> Enum.filter(&(&1.user_id == user.id and is_nil(&1.revoked_at)))

      assert live == []
    end
  end

  describe "an account a moderator disabled" do
    setup %{account: account, moderator: moderator} do
      {:ok, _} = Actions.take(moderator, account, "disable")
      :ok
    end

    test "loses the session it already had", %{conn: conn, user: user} do
      session = with_session(conn, user)

      assert redirected_to(get(session, ~p"/settings")) == ~p"/login"
    end
  end

  # Every assertion above is about a fresh request, which runs the plug
  # pipeline and is refused there. A LiveView asks once, at mount, and then
  # holds the answer for as long as the socket lives.
  describe "a page that was already open when the decision was made" do
    test "is sent away rather than left composing", %{
      conn: conn,
      user: user,
      account: account,
      moderator: moderator
    } do
      {:ok, live, _html} = live(with_session(conn, user), ~p"/home")

      {:ok, _} = Actions.take(moderator, account, "suspend")

      assert_redirect(live, ~p"/login")
      refute Process.alive?(live.pid)
    end

    test "and the compose box it was holding is gone with it", %{
      conn: conn,
      user: user,
      account: account,
      moderator: moderator
    } do
      # The sharp end of the one above: this posted, before the socket was told
      # anything, for as long as nobody reloaded the page.
      {:ok, live, _html} = live(with_session(conn, user), ~p"/home")

      {:ok, _} = Actions.take(moderator, account, "suspend")
      assert_redirect(live, ~p"/login")

      catch_exit(
        live
        |> form("#compose-form", draft: %{"text" => "still here"})
        |> render_submit()
      )

      assert Abuuba.Repo.all(Abuuba.Statuses.Status)
             |> Enum.filter(&(&1.account_id == account.id)) == []
    end

    test "and a public page it was on keeps being a public page", %{
      conn: conn,
      user: user,
      account: account,
      moderator: moderator
    } do
      # Closing an open page is not the same as refusing it. Explore answers
      # anybody, so it is drawn again as a stranger would get it: telling the
      # reader they have to be signed in to see a page a stranger can see would
      # be the interface arguing with itself.
      session = with_session(conn, user)
      {:ok, live, _html} = live(session, ~p"/explore")

      {:ok, _} = Actions.take(moderator, account, "suspend")

      assert_redirect(live, ~p"/explore")

      # The same browser, holding the same now-dead cookie.
      {:ok, _again, html} = live(session, ~p"/explore")

      assert html =~ "Log in"
      refute html =~ "Notifications"
    end

    test "and cannot go on acting from it", %{
      conn: conn,
      user: user,
      account: account,
      moderator: moderator
    } do
      # The sharp end of the one above. Clearing the reader out of the scope
      # fixes the navigation and leaves whatever the screen took out of it at
      # mount -- and it is that, not the scope, which the action bar acts
      # through, so anything short of a fresh mount leaves the buttons live.
      author = account_fixture(%{username: "poster"})
      status = status_fixture(%{account_id: author.id, text: "out here"})

      session = with_session(conn, user)
      {:ok, live, _html} = live(session, ~p"/explore")

      {:ok, _} = Actions.take(moderator, account, "suspend")
      assert_redirect(live, ~p"/explore")

      {:ok, _again, html} = live(session, ~p"/explore")

      assert html =~ "out here"
      refute html =~ ~s(phx-click="favourite")
      refute Statuses.favourited?(account.id, status.id)
    end

    test "signing out everywhere takes the page it was pressed on with it", %{
      conn: conn,
      user: user
    } do
      # The button says "including this one", and the page it was pressed on
      # went on working until somebody reloaded it.
      {:ok, live, _html} = live(with_session(conn, user), ~p"/settings/security")

      live |> element("button[phx-click='sign_out_everywhere']") |> render_click()

      assert_redirect(live, ~p"/login")
    end
  end

  # `Actions.take/4` does its work in one transaction, and the comment inside it
  # says why a broadcast may not go from there: it is the one thing that does
  # not come back on a rollback, and a subscriber on the same node is delivered
  # to synchronously -- so a page redrawing on the message could read the rows
  # from before the commit and come back signed in. The announcement is made
  # after it. Only that it still happens is testable here: the sandbox puts
  # every process on one connection, so before-commit and after-commit look the
  # same from a test.
  describe "the announcement that closes those pages" do
    test "still goes out, now that it waits for the commit", %{
      account: account,
      moderator: moderator
    } do
      Phoenix.PubSub.subscribe(Abuuba.PubSub, Auth.sessions_topic(user_id(account)))

      {:ok, _strike} = Actions.take(moderator, account, "suspend")

      assert_receive {:sessions, :revoked}, 500
    end
  end

  defp user_id(account) do
    Abuuba.Repo.get_by!(Abuuba.Accounts.User, account_id: account.id).id
  end
end
