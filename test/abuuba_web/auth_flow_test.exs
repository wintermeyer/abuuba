defmodule AbuubaWeb.AuthFlowTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.RateLimit
  alias Abuuba.Settings

  setup do
    RateLimit.reset()
    Settings.put_registration_mode(:open)
    :ok
  end

  defp register!(email \\ "alice@example.com", username \\ "alice") do
    {:ok, %{user: user}} =
      Auth.register(
        %{"username" => username, "email" => email, "password" => "correct horse battery"},
        rules_required: false
      )

    {:ok, token} = Auth.create_confirmation_token(user)
    {:ok, confirmed} = Auth.confirm_user(token)
    confirmed
  end

  describe "the signup wizard" do
    test "puts the rules in front of the form, not under it", %{conn: conn} do
      {:ok, _rule} = Settings.create_rule(%{text: "Be kind to each other"})

      {:ok, view, html} = live(conn, ~p"/register")

      assert html =~ "Be kind to each other"
      refute has_element?(view, "input#user_username")

      html = view |> element("button", "I have read the rules") |> render_click()

      assert html =~ "Username"
    end

    test "goes straight to the form when there are no rules to read", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/register")

      assert html =~ "Username"
    end

    test "says so when the server is closed", %{conn: conn} do
      Settings.put_registration_mode(:closed)

      {:ok, _view, html} = live(conn, ~p"/register")

      assert html =~ "Registrations are closed"
    end

    test "ends on confirm-your-email rather than signing anybody in", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      html =
        view
        |> form("form",
          user: %{
            username: "alice",
            email: "alice@example.com",
            password: "correct horse battery"
          }
        )
        |> render_submit()

      assert html =~ "Check your email"
      assert Auth.get_user_by_email("alice@example.com")
    end

    test "stops somebody signing up over and over from one place", %{conn: conn} do
      # The API sign-up route has been counted per address since it was
      # written. This form is a LiveView, so it submits over the socket and no
      # plug runs -- the same door, unguarded. Each attempt sends a
      # confirmation mail to an address the sender chose, which is how a server
      # becomes somebody else's mail bomber and loses its reputation.
      for i <- 1..5 do
        {:ok, view, _html} = live(conn, ~p"/register")

        view
        |> form("form",
          user: %{
            username: "flood#{i}",
            email: "flood#{i}@example.com",
            password: "correct horse battery"
          }
        )
        |> render_submit()

        assert Auth.get_user_by_email("flood#{i}@example.com"), "attempt #{i} should be allowed"
      end

      {:ok, view, _html} = live(conn, ~p"/register")

      html =
        view
        |> form("form",
          user: %{
            username: "flood6",
            email: "flood6@example.com",
            password: "correct horse battery"
          }
        )
        |> render_submit()

      assert html =~ "Too many"
      refute Auth.get_user_by_email("flood6@example.com")
    end

    test "shows every problem at once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      html =
        view
        |> form("form", user: %{username: "not valid", email: "nope", password: "x"})
        |> render_change()

      assert html =~ "letters, numbers and underscores"
      assert html =~ "must be an email address"
    end
  end

  describe "signing in" do
    test "works, and starts a session", %{conn: conn} do
      register!()

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"email" => "alice@example.com", "password" => "correct horse battery"}
        })

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
    end

    test "answers a wrong password and a missing account identically", %{conn: _conn} do
      register!()

      wrong =
        post(build_conn(), ~p"/login", %{
          "user" => %{"email" => "alice@example.com", "password" => "nope"}
        })

      missing =
        post(build_conn(), ~p"/login", %{
          "user" => %{"email" => "nobody@example.com", "password" => "nope"}
        })

      assert Phoenix.Flash.get(wrong.assigns.flash, :error) ==
               Phoenix.Flash.get(missing.assigns.flash, :error)

      refute get_session(wrong, :user_token)
      refute get_session(missing, :user_token)
    end

    test "refuses an unconfirmed account and says which gate is shut", %{conn: conn} do
      {:ok, _} =
        Auth.register(
          %{
            "username" => "bob",
            "email" => "bob@example.com",
            "password" => "correct horse battery"
          },
          rules_required: false
        )

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"email" => "bob@example.com", "password" => "correct horse battery"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Confirm your email"
      refute get_session(conn, :user_token)
    end

    test "refuses a pending registration without pretending the password was wrong", %{conn: conn} do
      Settings.put_registration_mode(:approved)

      {:ok, %{user: user}} =
        Auth.register(
          %{
            "username" => "carol",
            "email" => "carol@example.com",
            "password" => "correct horse battery",
            "invite_reason" => "hello"
          },
          rules_required: false
        )

      {:ok, token} = Auth.create_confirmation_token(user)
      {:ok, _} = Auth.confirm_user(token)

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"email" => "carol@example.com", "password" => "correct horse battery"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "moderator"
      refute get_session(conn, :user_token)
    end

    test "a filled honeypot is refused like a wrong password", %{conn: conn} do
      register!()

      conn =
        post(conn, ~p"/login", %{
          "user" => %{
            "email" => "alice@example.com",
            "password" => "correct horse battery",
            "website" => "https://spam.example"
          }
        })

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "do not match"
    end

    test "signing out ends the session", %{conn: conn} do
      register!()

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"email" => "alice@example.com", "password" => "correct horse battery"}
        })

      token = get_session(conn, :user_token)
      conn = conn |> recycle() |> delete(~p"/logout")

      refute get_session(conn, :user_token)
      refute Auth.get_user_by_session_token(token)
    end
  end

  describe "rate limiting" do
    test "cuts off a flood of attempts", %{conn: _conn} do
      # Counted until one is refused rather than assuming exactly which
      # attempt trips it, so a window boundary landing mid-loop cannot turn
      # this into an occasional failure.
      refused =
        Enum.find_value(1..40, fn _ ->
          conn =
            post(build_conn(), ~p"/login", %{
              "user" => %{"email" => "a@b.com", "password" => "x"}
            })

          message = Phoenix.Flash.get(conn.assigns.flash, :error)

          if message =~ "Too many attempts", do: message
        end)

      assert refused, "a flood of sign-in attempts was never refused"
    end
  end

  describe "confirming" do
    test "a good link confirms and sends you to sign in", %{conn: conn} do
      {:ok, %{user: user}} =
        Auth.register(
          %{
            "username" => "dave",
            "email" => "dave@example.com",
            "password" => "correct horse battery"
          },
          rules_required: false
        )

      {:ok, token} = Auth.create_confirmation_token(user)

      conn = get(conn, ~p"/confirm/#{token}")

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "confirmed"
    end

    test "a bad link says nothing about whether the address exists", %{conn: conn} do
      conn = get(conn, ~p"/confirm/nonsense")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not valid any more"
    end
  end

  describe "signing up on an invitation" do
    test "the page opens even when sign-ups are closed", %{conn: conn} do
      # The link in the invitation has to work, or the code is one nobody can
      # use.
      inviter = inviter_account()
      :ok = Abuuba.Settings.put_registration_mode("closed")
      {:ok, invite} = Abuuba.Invites.create(inviter, %{})

      {:ok, _live, html} = live(conn, ~p"/register?invite=#{invite.code}")

      assert html =~ invite.code
    end

    test "and stays closed without one", %{conn: conn} do
      :ok = Abuuba.Settings.put_registration_mode("closed")

      {:ok, _live, html} = live(conn, ~p"/register")

      refute html =~ "user[username]"
    end
  end

  defp inviter_account do
    {:ok, role} =
      Abuuba.Roles.create(%{
        name: "Inviter #{System.unique_integer([:positive])}",
        position: 10,
        permissions: Abuuba.Roles.mask(["invite_users"])
      })

    account = account_fixture()
    user = user_fixture(%{account_id: account.id, approved: true})
    {:ok, _} = Abuuba.Roles.assign(user, role)

    account
  end
end
