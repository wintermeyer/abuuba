defmodule AbuubaWeb.TwoFactorFlowTest do
  use AbuubaWeb.ConnCase, async: false

  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.TwoFactor
  alias Abuuba.Accounts.User
  alias Abuuba.RateLimit
  alias Abuuba.Repo
  alias Abuuba.Settings

  @password "correct horse battery"

  setup do
    RateLimit.reset()
    Settings.put_registration_mode(:open)

    {:ok, %{user: user}} =
      Auth.register(
        %{"username" => "alice", "email" => "alice@example.com", "password" => @password},
        rules_required: false
      )

    {:ok, token} = Auth.create_confirmation_token(user)
    {:ok, user} = Auth.confirm_user(token)

    %{user: user}
  end

  defp enrol(user) do
    {:ok, %{secret: secret}} = TwoFactor.begin_totp_enrolment(user)
    reloaded = Repo.get!(User, user.id)
    {:ok, enrolled, codes} = TwoFactor.confirm_totp_enrolment(reloaded, code_for(secret))

    # Enrolment consumes the current window; clear it so the test can use one.
    enrolled = Repo.update!(Ecto.Changeset.change(enrolled, otp_last_used_at: nil))

    %{user: enrolled, secret: secret, codes: codes}
  end

  defp code_for(secret), do: NimbleTOTP.verification_code(secret)

  defp sign_in(conn) do
    post(conn, ~p"/login", %{"user" => %{"email" => "alice@example.com", "password" => @password}})
  end

  test "an account without a second factor signs straight in", %{conn: conn} do
    conn = sign_in(conn)

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_token)
  end

  test "the password alone gets no session when a second factor is set", %{conn: conn, user: user} do
    enrol(user)

    conn = sign_in(conn)

    assert redirected_to(conn) == ~p"/login/two-factor"

    refute get_session(conn, :user_token),
           "the password alone must not be a session"
  end

  test "the right code finishes the sign-in", %{conn: conn, user: user} do
    %{secret: secret} = enrol(user)

    conn = conn |> sign_in() |> recycle_with_session()
    conn = post(conn, ~p"/login/two-factor", %{"user" => %{"code" => code_for(secret)}})

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_token)
  end

  test "a recovery code works at the same prompt", %{conn: conn, user: user} do
    %{codes: [code | _]} = enrol(user)

    conn = conn |> sign_in() |> recycle_with_session()
    conn = post(conn, ~p"/login/two-factor", %{"user" => %{"code" => code}})

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_token)
  end

  test "a used recovery code does not work twice", %{conn: conn, user: user} do
    %{codes: [code | _]} = enrol(user)

    conn = conn |> sign_in() |> recycle_with_session()
    post(conn, ~p"/login/two-factor", %{"user" => %{"code" => code}})

    conn =
      conn
      |> recycle_with_session()
      |> post(~p"/login/two-factor", %{"user" => %{"code" => code}})

    refute get_session(conn, :user_token)
  end

  test "a wrong code gets no session", %{conn: conn, user: user} do
    enrol(user)

    conn = conn |> sign_in() |> recycle_with_session()
    conn = post(conn, ~p"/login/two-factor", %{"user" => %{"code" => "000000"}})

    assert redirected_to(conn) == ~p"/login/two-factor"
    refute get_session(conn, :user_token)
  end

  test "the second step is useless without having passed the first", %{conn: conn, user: user} do
    %{secret: secret} = enrol(user)

    conn = post(conn, ~p"/login/two-factor", %{"user" => %{"code" => code_for(secret)}})

    refute get_session(conn, :user_token),
           "knowing a valid code must not be enough on its own"
  end

  # Carries the session across, which is what a browser does and what the
  # pending-user id depends on.
  defp recycle_with_session(conn) do
    session = Plug.Conn.get_session(conn)

    build_conn()
    |> Plug.Test.init_test_session(session)
  end
end
