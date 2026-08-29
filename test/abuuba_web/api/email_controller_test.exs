defmodule AbuubaWeb.API.EmailControllerTest do
  use AbuubaWeb.ConnCase, async: false

  alias Abuuba.Accounts.User
  alias Abuuba.OAuth
  alias Abuuba.RateLimit
  alias Abuuba.Repo
  alias Abuuba.Settings

  setup %{conn: conn} do
    RateLimit.reset()
    Settings.put_registration_mode(:open)

    {:ok, application, _secret} =
      OAuth.create_application(%{
        name: "an app",
        redirect_uris: "urn:ietf:wg:oauth:2.0:oob",
        scopes: "read write"
      })

    {:ok, _token, app_token} =
      OAuth.issue_client_credentials_token(application, ["read", "write"])

    %{
      app_conn: put_req_header(conn, "authorization", "Bearer " <> app_token),
      anon: build_conn(),
      application: application
    }
  end

  # The whole flow this endpoint exists for: an app signs somebody up and holds
  # a token that can do nothing else until the address is confirmed.
  defp signed_up(app_conn, username) do
    body =
      json_response(
        post(app_conn, "/api/v1/accounts", %{
          "username" => username,
          "email" => "#{username}@example.com",
          "password" => "a long enough password",
          "agreement" => "true"
        }),
        200
      )

    account = Abuuba.Accounts.lookup(username)

    %{
      conn: put_req_header(build_conn(), "authorization", "Bearer " <> body["access_token"]),
      user: Repo.get_by(User, account_id: account.id)
    }
  end

  describe "asking for the mail again" do
    test "sends it, and says nothing else", %{app_conn: app_conn} do
      %{conn: conn, user: user} = signed_up(app_conn, "waiting")

      assert json_response(post(conn, "/api/v1/emails/confirmations", %{}), 200) == %{}
      assert_received {:email, %Swoosh.Email{to: [{_name, address}]}} when address == user.email
    end

    test "corrects an address that was mistyped", %{app_conn: app_conn} do
      # The common reason somebody asks for it again is that the first one went
      # to an address with a typo in it.
      %{conn: conn, user: user} = signed_up(app_conn, "mistyped")

      assert json_response(
               post(conn, "/api/v1/emails/confirmations", %{"email" => "right@example.com"}),
               200
             ) == %{}

      assert Repo.get(User, user.id).email == "right@example.com"
    end

    test "refuses an address that is not one", %{app_conn: app_conn} do
      %{conn: conn} = signed_up(app_conn, "typo")

      assert json_response(
               post(conn, "/api/v1/emails/confirmations", %{"email" => "not an address"}),
               422
             )
    end

    test "is refused to an app that did not make the account", %{app_conn: app_conn} do
      # An app that did not sign somebody up has no business sending them mail,
      # and the address it would send to is one it could change on the way.
      %{user: user} = signed_up(app_conn, "notyours")

      {:ok, other, _secret} =
        OAuth.create_application(%{name: "other", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

      {:ok, _token, raw} = OAuth.issue_token(other, user, ["read", "write"])

      body =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post("/api/v1/emails/confirmations", %{})
        |> json_response(403)

      assert body["error"] =~ "originally signed-up with"
    end

    test "is refused once the address is confirmed", %{app_conn: app_conn} do
      # Otherwise it is a way to send somebody mail they did not ask for.
      %{conn: conn, user: user} = signed_up(app_conn, "confirmed")

      {:ok, _} = user |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now()) |> Repo.update()

      body = json_response(post(conn, "/api/v1/emails/confirmations", %{}), 403)

      assert body["error"] =~ "awaiting confirmation"
    end

    test "needs a token at all", %{anon: anon} do
      assert json_response(post(anon, "/api/v1/emails/confirmations", %{}), 401)
    end

    test "is bounded, because it sends mail to an address a stranger chose", %{
      app_conn: app_conn
    } do
      %{conn: conn} = signed_up(app_conn, "insistent")

      results = for _ <- 1..8, do: post(conn, "/api/v1/emails/confirmations", %{}).status

      assert 429 in results
    end
  end

  describe "polling for the answer" do
    test "says false, then true", %{app_conn: app_conn} do
      %{conn: conn, user: user} = signed_up(app_conn, "polling")

      assert json_response(get(conn, "/api/v1/emails/check_confirmation"), 200) == false

      {:ok, _} = user |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now()) |> Repo.update()

      assert json_response(get(conn, "/api/v1/emails/check_confirmation"), 200) == true
    end

    test "needs a token", %{anon: anon} do
      assert json_response(get(anon, "/api/v1/emails/check_confirmation"), 401)
    end
  end
end
