defmodule AbuubaWeb.API.AccountRegistrationTest do
  use AbuubaWeb.ConnCase, async: false

  import Ecto.Query
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.User
  alias Abuuba.Accounts.UserToken
  alias Abuuba.Admin
  alias Abuuba.Invites
  alias Abuuba.Moderation.Signup
  alias Abuuba.OAuth
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Settings

  setup %{conn: conn} do
    {:ok, application, _secret} =
      OAuth.create_application(%{
        name: "an app",
        redirect_uris: "urn:ietf:wg:oauth:2.0:oob",
        scopes: "read write follow"
      })

    {:ok, _token, app_token} =
      OAuth.issue_client_credentials_token(application, ["read", "write", "follow"])

    Settings.put_registration_mode(:open)

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> app_token),
      anon: build_conn(),
      application: application
    }
  end

  defp with_invite_permission(account) do
    {:ok, role} =
      Roles.create(%{
        name: "Inviter #{System.unique_integer([:positive])}",
        position: 10,
        permissions: Roles.mask(["invite_users"])
      })

    user = user_fixture(%{account_id: account.id, approved: true})
    {:ok, _} = Roles.assign(user, role)

    account
  end

  defp signup(conn, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          "username" => "newcomer#{System.unique_integer([:positive])}",
          "email" => "newcomer#{System.unique_integer([:positive])}@example.com",
          "password" => "a long enough password",
          "agreement" => "true",
          "locale" => "en"
        },
        overrides
      )

    post(conn, "/api/v1/accounts", params)
  end

  describe "signing somebody up" do
    test "answers with a token that works", %{conn: conn} do
      body = json_response(signup(conn), 200)

      assert body["token_type"] == "Bearer"
      assert is_binary(body["access_token"])
      assert is_integer(body["created_at"])
      # Canonical order, which is what every scope string in this API uses.
      assert body["scope"] == "follow read write"

      # Before the address is confirmed the token is real but the account
      # cannot act, which is exactly what the app needs to be able to show.
      signed_in =
        build_conn() |> put_req_header("authorization", "Bearer " <> body["access_token"])

      assert json_response(get(signed_in, "/api/v1/accounts/verify_credentials"), 403)

      # The positive control, and the whole point of the endpoint: once the
      # address is confirmed the same token works, with no second sign-in.
      user = Repo.one!(from(u in User, order_by: [desc: u.id], limit: 1))
      {:ok, _} = user |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now()) |> Repo.update()

      me = signed_in |> get("/api/v1/accounts/verify_credentials") |> json_response(200)

      assert is_binary(me["username"])
    end

    test "makes the account, the user and the keypair", %{conn: conn} do
      json_response(signup(conn, %{"username" => "brandnew"}), 200)

      account = Accounts.lookup("brandnew")

      assert account
      assert Repo.get_by(User, account_id: account.id)
      assert Accounts.active_keypair(account)
    end

    test "records the reason the moderators will read", %{conn: conn} do
      Settings.put_registration_mode(:approved)

      json_response(
        signup(conn, %{"username" => "hopeful", "reason" => "I like it here"}),
        200
      )

      account = Accounts.lookup("hopeful")
      user = Repo.get_by(User, account_id: account.id)

      refute user.approved
      assert user.sign_up_reason == "I like it here"
    end

    test "sends the two mails a new account is owed", %{conn: conn} do
      Settings.put_registration_mode(:approved)

      json_response(signup(conn, %{"username" => "mailed", "reason" => "hello"}), 200)

      account = Accounts.lookup("mailed")
      user = Repo.get_by(User, account_id: account.id)

      # The link is what makes the account usable at all, so a sign-up that
      # quietly sent nothing would leave somebody stuck with no way to know why.
      assert_received {:email, %Swoosh.Email{to: [{_name, address}]}} when address == user.email
      assert Repo.exists?(from(t in UserToken, where: t.user_id == ^user.id))
    end

    test "records the address it was signed up from", %{conn: conn} do
      # Without it an address block written after a wave of sign-ups has
      # nothing to match, and the wave cannot be seen for what it was.
      json_response(signup(conn, %{"username" => "tracked"}), 200)

      account = Accounts.lookup("tracked")

      assert Repo.get_by(User, account_id: account.id).sign_up_ip == "127.0.0.1"
    end

    test "an address the moderators put a hold on lands in the pending queue", %{conn: conn} do
      # And is visible there. An account flagged for approval that no query
      # returns is one nobody can ever let in.
      {:ok, _block} =
        Signup.block_ip(account_fixture(), %{
          "cidr" => "127.0.0.1",
          "severity" => "sign_up_requires_approval"
        })

      json_response(signup(conn, %{"username" => "onhold", "reason" => "let me in"}), 200)

      account = Accounts.lookup("onhold")
      user = Repo.get_by(User, account_id: account.id)

      refute user.approved
      refute User.disabled?(user)
      assert %{reason: "let me in"} = Admin.pending_user_ids([account])[account.id]
    end

    test "refuses a reason longer than the box allows", %{conn: conn} do
      body =
        json_response(
          signup(conn, %{"username" => "wordy", "reason" => String.duplicate("x", 500)}),
          422
        )

      # Named the way the client named it, not the way the column does.
      assert body["details"]["reason"]
      assert Accounts.lookup("wordy") == nil
    end

    test "will not take a language it does not have", %{conn: conn} do
      # It decides which language every mail this person ever gets goes out in.
      json_response(
        signup(conn, %{"username" => "elsewhere", "locale" => "../../etc/passwd"}),
        200
      )

      account = Accounts.lookup("elsewhere")

      assert Repo.get_by(User, account_id: account.id).locale == nil
    end

    test "stops an app making accounts by the thousand", %{conn: conn} do
      # The general API budget is three hundred requests in five minutes, which
      # is three hundred accounts. Sign-up has a budget of its own.
      results = for _ <- 1..7, do: signup(conn).status

      assert 429 in results
    end

    test "refuses a form with problems, and says which", %{conn: conn} do
      body = json_response(signup(conn, %{"username" => "not a username"}), 422)

      assert body["error"] =~ "Validation failed"
      assert body["details"]["username"]
    end

    test "will not agree on somebody's behalf", %{conn: conn} do
      body = json_response(signup(conn, %{"agreement" => "false"}), 422)

      assert body["details"]["agreement"]
    end
  end

  describe "who may ask" do
    test "a token with a person behind it is refused", %{conn: _conn} do
      # Signing somebody up is the app acting as itself. A user token here
      # would be one person's session creating another person's account.
      account = account_fixture()

      user =
        user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

      {:ok, application, _secret} =
        OAuth.create_application(%{name: "b", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

      {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

      body =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> signup(%{"username" => "byproxy"})
        |> json_response(403)

      assert body["error"] =~ "client credentials"
      assert Accounts.lookup("byproxy") == nil
    end

    test "a read-only token cannot make accounts", %{} do
      {:ok, application, _secret} =
        OAuth.create_application(%{
          name: "reader",
          redirect_uris: "urn:ietf:wg:oauth:2.0:oob",
          scopes: "read"
        })

      {:ok, _token, raw} = OAuth.issue_client_credentials_token(application, ["read"])

      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> raw)
             |> signup(%{"username" => "readonly"})
             |> json_response(403)

      assert Accounts.lookup("readonly") == nil
    end

    test "no token at all is refused", %{anon: anon} do
      assert json_response(signup(anon, %{"username" => "tokenless"}), 401)
      assert Accounts.lookup("tokenless") == nil
    end
  end

  describe "when the server is not taking anybody" do
    test "a closed server refuses", %{conn: conn} do
      Settings.put_registration_mode(:closed)

      assert json_response(signup(conn, %{"username" => "unwanted"}), 403)
      assert Accounts.lookup("unwanted") == nil
    end

    test "an invite still opens it", %{conn: conn} do
      Settings.put_registration_mode(:closed)

      {:ok, invite} = Invites.create(with_invite_permission(account_fixture()), %{})

      assert json_response(
               signup(conn, %{"username" => "invited", "invite_code" => invite.code}),
               200
             )

      assert Accounts.lookup("invited")
    end

    test "an invite code that is not one is refused rather than ignored", %{conn: conn} do
      Settings.put_registration_mode(:closed)

      assert json_response(signup(conn, %{"invite_code" => "nonsense"}), 403)
    end
  end

  describe "the puzzle" do
    setup do
      Application.put_env(:abuuba, Abuuba.Moderation.Signup.Captcha,
        site_key: "site",
        secret: "secret"
      )

      on_exit(fn -> Application.delete_env(:abuuba, Abuuba.Moderation.Signup.Captcha) end)
      :ok
    end

    test "is refused when the server asks for one and the client sent none", %{conn: conn} do
      body = json_response(signup(conn, %{"username" => "puzzled"}), 422)

      assert body["error"] =~ "puzzle"
      assert Accounts.lookup("puzzled") == nil
    end
  end

  describe "fetching several accounts at once" do
    test "returns the ones that exist and skips the rest", %{anon: anon} do
      one = account_fixture()

      _user =
        user_fixture(%{account_id: one.id, approved: true, confirmed_at: DateTime.utc_now()})

      two = remote_account_fixture()

      body =
        anon
        |> get("/api/v1/accounts", %{"id" => [to_string(one.id), to_string(two.id), "999999"]})
        |> json_response(200)

      assert body |> Enum.map(& &1["id"]) |> Enum.sort() ==
               Enum.sort([to_string(one.id), to_string(two.id)])
    end

    test "leaves out a local account nobody has approved yet", %{anon: anon} do
      # Their profile does not exist for anybody else until it does, and a
      # batch fetch must not be the door around that.
      pending = account_fixture()
      _user = user_fixture(%{account_id: pending.id, approved: false})

      unconfirmed = account_fixture()
      _other = user_fixture(%{account_id: unconfirmed.id, approved: true, confirmed_at: nil})

      visible = account_fixture()

      _fine =
        user_fixture(%{account_id: visible.id, approved: true, confirmed_at: DateTime.utc_now()})

      ids = Enum.map([pending, unconfirmed, visible], &to_string(&1.id))

      body = anon |> get("/api/v1/accounts", %{"id" => ids}) |> json_response(200)

      assert Enum.map(body, & &1["id"]) == [to_string(visible.id)]
    end

    test "refuses a list longer than the limit", %{anon: anon} do
      ids = Enum.map(1..41, &to_string/1)

      assert json_response(get(anon, "/api/v1/accounts", %{"id" => ids}), 422)
    end

    test "an empty list is an empty answer", %{anon: anon} do
      assert json_response(get(anon, "/api/v1/accounts", %{}), 200) == []
    end
  end
end
