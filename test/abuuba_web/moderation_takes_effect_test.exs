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

  alias Abuuba.Accounts.Auth
  alias Abuuba.Moderation.Actions

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
end
