defmodule AbuubaWeb.PasswordResetTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.User
  alias Abuuba.Accounts.UserToken
  alias Abuuba.OAuth
  alias Abuuba.RateLimit
  alias Abuuba.Repo

  @password "a passphrase nobody guesses"
  @new_password "another passphrase entirely"

  setup do
    account = account_fixture()

    user =
      %{account_id: account.id, email: "alice@example.com", approved: true}
      |> Map.put(:confirmed_at, DateTime.utc_now())
      |> user_fixture()
      |> with_password(@password)

    on_exit(&RateLimit.reset/0)
    RateLimit.reset()

    %{account: account, user: user}
  end

  # `user_fixture/1` does not take a password, and every assertion here is about
  # one.
  defp with_password(user, password) do
    user |> User.password_changeset(%{password: password}) |> Repo.update!()
  end

  defp flash(conn, key), do: Phoenix.Flash.get(conn.assigns.flash, key)

  # Asking for a reset queues the lookup rather than doing it, so that the
  # request costs the same whether or not the address has an account here. Every
  # assertion about mail therefore runs the queue first.
  defp drain, do: Oban.drain_queue(queue: :ingress)

  # What actually reached a mailbox, counted from the messages the test adapter
  # sends here, rather than from the limiter's own opinion of what it allowed.
  defp mail_sent do
    Stream.unfold(nil, fn _ ->
      receive do
        {:email, email} -> {email, nil}
      after
        0 -> nil
      end
    end)
    |> Enum.to_list()
  end

  defp token_for(user) do
    {:ok, token} = Auth.create_reset_token(user)

    token
  end

  describe "asking for a link" do
    test "sends one to an address that has an account", %{conn: conn, user: user} do
      conn
      |> post(~p"/reset-password", %{"user" => %{"email" => user.email}})
      |> redirected_to()

      drain()

      assert_email_sent(fn email ->
        assert {_name, "alice@example.com"} = hd(email.to)
        assert email.text_body =~ "/reset-password/"
      end)
    end

    test "answers the same for an address that has none, and sends nothing", %{conn: conn} do
      mine =
        conn
        |> post(~p"/reset-password", %{"user" => %{"email" => "alice@example.com"}})
        |> flash(:info)

      theirs =
        build_conn()
        |> post(~p"/reset-password", %{"user" => %{"email" => "nobody@example.com"}})
        |> flash(:info)

      # Telling the two apart would make this form a way of finding out who has
      # an account here, and asking needs nothing but the address.
      assert mine == theirs
      drain()
      assert_email_sent()
      drain()
      refute_email_sent()
    end

    test "does not mail one address more than a few times an hour", %{conn: conn, user: user} do
      # The request limiter counts client addresses, which does nothing about
      # several of them pointed at one mailbox.
      for _ <- 1..6 do
        conn
        |> post(~p"/reset-password", %{"user" => %{"email" => user.email}})
        |> redirected_to()
      end

      drain()

      assert length(mail_sent()) == 3
    end

    test "leaves only one link live, however many times it is asked", %{conn: conn, user: user} do
      first = token_for(user)
      _second = token_for(user)

      _ = conn

      # Two live links is two chances for one to be found, and a row per ask is
      # a table anybody can fill.
      assert is_nil(Auth.get_user_by_reset_token(first))
    end

    test "is throttled the way signing in is", %{conn: conn} do
      for _ <- 1..20 do
        post(conn, ~p"/reset-password", %{"user" => %{"email" => "nobody@example.com"}})
      end

      assert conn
             |> post(~p"/reset-password", %{"user" => %{"email" => "nobody@example.com"}})
             |> flash(:error)
    end
  end

  describe "what the limit on that mail must not give away" do
    test "and the answer never says which it did", %{conn: conn, user: user} do
      # The wording and the redirect cannot change when the limit bites, or the
      # form becomes a way of finding out which addresses have been asked about
      # lately.
      first = conn |> post(~p"/reset-password", %{"user" => %{"email" => user.email}})

      later =
        Enum.map(1..8, fn _ ->
          build_conn() |> post(~p"/reset-password", %{"user" => %{"email" => user.email}})
        end)
        |> List.last()

      assert flash(first, :info) == flash(later, :info)
      assert redirected_to(first) == redirected_to(later)
    end

    test "and somebody else can still ask", %{conn: conn, user: user} do
      # The positive control: a limit that had stopped everybody would satisfy
      # the first test just as well.
      for _ <- 1..10 do
        build_conn() |> post(~p"/reset-password", %{"user" => %{"email" => user.email}})
      end

      other = user_fixture(%{email: "carol@example.com"})

      conn |> post(~p"/reset-password", %{"user" => %{"email" => other.email}}) |> redirected_to()

      drain()

      addresses = for email <- mail_sent(), {_name, address} <- email.to, do: address

      assert "carol@example.com" in addresses
    end
  end

  describe "the request page" do
    test "renders and offers the form", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/reset-password")

      assert html =~ "Forgotten password"
      assert html =~ "reset-request-form"
    end

    test "is linked from the sign-in page", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/login")

      assert html =~ ~p"/reset-password"
    end
  end

  describe "the page behind a link" do
    test "asks for a new password when the token is good", %{conn: conn, user: user} do
      {:ok, _live, html} = live(conn, ~p"/reset-password/#{token_for(user)}")

      assert html =~ "Set a new password"
      assert html =~ "reset-form"
    end

    test "says so before the field when the token is not", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/reset-password/nonsense")

      # Before somebody has thought of a password and typed it, not after.
      assert html =~ "no good any more"
      refute html =~ "reset-form"
    end
  end

  describe "setting the new password" do
    test "works, and lets them sign in with it", %{conn: conn, user: user} do
      conn
      |> post(~p"/reset-password/#{token_for(user)}", %{"user" => %{"password" => @new_password}})
      |> redirected_to()

      assert %User{} = Auth.get_user_by_email_and_password(user.email, @new_password)
      refute Auth.get_user_by_email_and_password(user.email, @password)
    end

    test "refuses one that is too short, and leaves the old one working", %{
      conn: conn,
      user: user
    } do
      conn
      |> post(~p"/reset-password/#{token_for(user)}", %{"user" => %{"password" => "short"}})
      |> redirected_to()

      assert %User{} = Auth.get_user_by_email_and_password(user.email, @password)
    end

    # The rows go inside the transaction here rather than through
    # `delete_all_session_tokens/1`, so this path is the one that would
    # silently not announce -- and it is the one whose whole purpose is
    # somebody else being in the account. A page left open is a session that
    # is still working.
    test "closes the pages those sessions had open", %{conn: conn, user: user} do
      intruder =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))

      {:ok, live, _html} = live(intruder, ~p"/home")

      Phoenix.ConnTest.build_conn()
      |> post(~p"/reset-password/#{token_for(user)}", %{
        "user" => %{"password" => @new_password}
      })
      |> redirected_to()

      assert_redirect(live, ~p"/login")
    end

    test "burns the link", %{conn: conn, user: user} do
      token = token_for(user)

      conn
      |> post(~p"/reset-password/#{token}", %{"user" => %{"password" => @new_password}})
      |> redirected_to()

      assert is_nil(Auth.get_user_by_reset_token(token))
    end

    test "kills every other link that was outstanding", %{conn: conn, user: user} do
      older = token_for(user)
      newer = token_for(user)

      conn
      |> post(~p"/reset-password/#{newer}", %{"user" => %{"password" => @new_password}})
      |> redirected_to()

      assert is_nil(Auth.get_user_by_reset_token(older))
    end

    test "signs out every session", %{conn: conn, user: user} do
      session = Auth.create_session_token(user)
      assert %User{} = Auth.get_user_by_session_token(session)

      conn
      |> post(~p"/reset-password/#{token_for(user)}", %{"user" => %{"password" => @new_password}})
      |> redirected_to()

      assert is_nil(Auth.get_user_by_session_token(session))
    end

    test "revokes every app's token", %{conn: conn, user: user} do
      {:ok, application, _secret} =
        OAuth.create_application(%{name: "app", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

      {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

      # A positive control for the refutation that follows: without it a broken
      # setup would pass this test having exercised nothing.
      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> raw)
             |> get(~p"/api/v1/accounts/verify_credentials")
             |> json_response(200)

      conn
      |> post(~p"/reset-password/#{token_for(user)}", %{"user" => %{"password" => @new_password}})
      |> redirected_to()

      # An app that stayed signed in keeps whoever installed it signed in too,
      # and a reset is usually somebody trying to get another person out.
      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> raw)
             |> get(~p"/api/v1/accounts/verify_credentials")
             |> json_response(422)
    end

    test "kills an OAuth code that was approved but never redeemed", %{conn: conn, user: user} do
      {:ok, application, _secret} =
        OAuth.create_application(%{
          name: "app",
          redirect_uris: "https://client.example/cb",
          scopes: "read write"
        })

      exchange = fn code ->
        OAuth.exchange_authorization_code(code,
          application: application,
          redirect_uri: "https://client.example/cb"
        )
      end

      new_code = fn ->
        {:ok, code} =
          OAuth.create_authorization_code(application, user,
            redirect_uri: "https://client.example/cb",
            scopes: ["read"]
          )

        code
      end

      # A positive control: without it a rejected exchange proves nothing about
      # the reset, since a code this test never managed to mint would fail too.
      assert {:ok, _token, _raw} = exchange.(new_code.())

      code = new_code.()

      conn
      |> post(~p"/reset-password/#{token_for(user)}", %{"user" => %{"password" => @new_password}})
      |> redirected_to()

      # A code is a token that has not been collected yet. Somebody who
      # approved an app before the reset and simply did not redeem the code
      # could redeem it after, and be handed a live token by a server that
      # thinks it just locked everybody out.
      assert {:error, _reason} = exchange.(code)
    end

    test "leaves the second factor in place", %{conn: conn, user: user} do
      user
      |> Ecto.Changeset.change(
        otp_secret: "JBSWY3DPEHPK3PXP",
        otp_required_at: DateTime.utc_now()
      )
      |> Repo.update!()

      conn
      |> post(~p"/reset-password/#{token_for(user)}", %{"user" => %{"password" => @new_password}})
      |> redirected_to()

      # A reset proves control of a mailbox, and a mailbox is exactly what the
      # second factor exists to survive.
      reloaded = Repo.reload!(user)
      assert reloaded.otp_required_at
      assert reloaded.otp_secret == "JBSWY3DPEHPK3PXP"
    end

    test "confirms an address that never was", %{conn: conn, account: account} do
      _ = account

      unconfirmed =
        %{account_id: account_fixture().id, email: "bob@example.com", approved: true}
        |> user_fixture()
        |> with_password(@password)

      conn
      |> post(~p"/reset-password/#{token_for(unconfirmed)}", %{
        "user" => %{"password" => @new_password}
      })
      |> redirected_to()

      # Following the link is the same proof confirmation asks for, and a
      # working password somebody still cannot sign in with helps nobody.
      assert Repo.reload!(unconfirmed).confirmed_at
    end

    test "refuses a token that is not one", %{conn: conn} do
      assert conn
             |> post(~p"/reset-password/nonsense", %{"user" => %{"password" => @new_password}})
             |> flash(:error)
    end

    test "refuses one that has aged out", %{conn: conn, user: user} do
      token = token_for(user)

      UserToken
      |> Abuuba.Repo.all()
      |> Enum.each(fn row ->
        row
        |> Ecto.Changeset.change(
          inserted_at:
            DateTime.add(DateTime.utc_now(), -UserToken.reset_validity_hours() - 1, :hour)
        )
        |> Repo.update!()
      end)

      conn
      |> post(~p"/reset-password/#{token}", %{"user" => %{"password" => @new_password}})
      |> redirected_to()

      assert %User{} = Auth.get_user_by_email_and_password(user.email, @password)
    end

    test "a reset token is not a confirmation token", %{user: user} do
      # The context is what keeps one kind of link from working as another.
      assert :error = Auth.confirm_user(token_for(user))
    end
  end

  describe "GET /.well-known/change-password" do
    test "points a password manager at the page that changes one", %{conn: conn} do
      assert conn |> get(~p"/.well-known/change-password") |> redirected_to() =~
               "/settings/security"
    end
  end
end
