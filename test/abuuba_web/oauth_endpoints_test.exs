defmodule AbuubaWeb.OAuthEndpointsTest do
  use AbuubaWeb.ConnCase, async: false

  alias Abuuba.Accounts.Auth
  alias Abuuba.OAuth
  alias Abuuba.RateLimit
  alias Abuuba.Settings

  setup do
    RateLimit.reset()
    Settings.put_registration_mode(:open)
    :ok
  end

  defp app_fixture(scopes \\ "read write") do
    {:ok, application, secret} =
      OAuth.create_application(%{
        name: "Test Client",
        redirect_uris: "https://app.example/callback",
        scopes: scopes
      })

    {application, secret}
  end

  defp user_fixture do
    {:ok, %{user: user}} =
      Auth.register(
        %{
          "username" => "alice#{System.unique_integer([:positive])}",
          "email" => "alice#{System.unique_integer([:positive])}@example.com",
          "password" => "correct horse battery"
        },
        rules_required: false
      )

    user
  end

  describe "POST /api/v1/apps" do
    test "registers without any credentials, because it has to", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/apps", %{
          "client_name" => "My Client",
          "redirect_uris" => "https://app.example/cb",
          "scopes" => "read write"
        })

      body = json_response(conn, 200)

      assert body["name"] == "My Client"
      assert body["client_id"]
      assert body["client_secret"]
      assert body["vapid_key"]
    end

    test "accepts redirect_uris as a list, which some clients send", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/apps", %{
          "client_name" => "Listy",
          "redirect_uris" => ["https://a.example/cb", "myapp://oauth"]
        })

      assert json_response(conn, 200)["redirect_uris"] == [
               "https://a.example/cb",
               "myapp://oauth"
             ]
    end

    test "refuses a nonsense registration", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/apps", %{"client_name" => "", "redirect_uris" => "nope"})

      assert json_response(conn, 422)["error"]
    end
  end

  describe "POST /oauth/token" do
    test "exchanges a code", %{conn: conn} do
      {application, secret} = app_fixture()
      user = user_fixture()

      {:ok, code} =
        OAuth.create_authorization_code(application, user,
          redirect_uri: "https://app.example/callback",
          scopes: ["read"]
        )

      conn =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => application.client_id,
          "client_secret" => secret,
          "redirect_uri" => "https://app.example/callback"
        })

      body = json_response(conn, 200)

      assert body["token_type"] == "Bearer"
      assert body["scope"] == "read"
      assert OAuth.get_token(body["access_token"])
    end

    test "issues a client_credentials token", %{conn: conn} do
      {application, secret} = app_fixture()

      conn =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "client_credentials",
          "client_id" => application.client_id,
          "client_secret" => secret,
          "scope" => "read"
        })

      assert json_response(conn, 200)["access_token"]
    end

    test "refuses the password grant by name", %{conn: conn} do
      # Told it is unsupported, rather than told the request was malformed.
      {application, secret} = app_fixture()

      conn =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "password",
          "client_id" => application.client_id,
          "client_secret" => secret,
          "username" => "alice@example.com",
          "password" => "correct horse battery"
        })

      assert json_response(conn, 400)["error"] == "unsupported_grant_type"
    end

    test "refuses a wrong client secret", %{conn: conn} do
      {application, _secret} = app_fixture()

      conn =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "client_credentials",
          "client_id" => application.client_id,
          "client_secret" => "wrong"
        })

      assert json_response(conn, 401)["error"] == "invalid_client"
    end

    test "narrows client_credentials to what the app registered for", %{conn: conn} do
      {application, secret} = app_fixture("read")

      conn =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "client_credentials",
          "client_id" => application.client_id,
          "client_secret" => secret,
          "scope" => "read write"
        })

      assert json_response(conn, 200)["scope"] == "read"
    end
  end

  describe "POST /oauth/revoke" do
    test "revokes and reports success either way", %{conn: conn} do
      {application, secret} = app_fixture()
      user = user_fixture()
      {:ok, _token, raw} = OAuth.issue_token(application, user, ["read"])

      conn =
        post(conn, ~p"/oauth/revoke", %{
          "client_id" => application.client_id,
          "client_secret" => secret,
          "token" => raw
        })

      assert json_response(conn, 200) == %{}
      refute OAuth.get_token(raw)

      # A token that never existed answers the same way, so the endpoint is not
      # a way to test whether one is valid.
      conn =
        post(build_conn(), ~p"/oauth/revoke", %{
          "client_id" => application.client_id,
          "client_secret" => secret,
          "token" => "never existed"
        })

      assert json_response(conn, 200) == %{}
    end
  end

  describe "the metadata document" do
    test "advertises only the grants and challenge methods we actually offer", %{conn: conn} do
      body = conn |> get(~p"/.well-known/oauth-authorization-server") |> json_response(200)

      assert body["grant_types_supported"] == ["authorization_code", "client_credentials"]
      assert body["code_challenge_methods_supported"] == ["S256"]
      assert body["response_types_supported"] == ["code"]
      assert "read:statuses" in body["scopes_supported"]

      refute "password" in body["grant_types_supported"]
      refute "plain" in body["code_challenge_methods_supported"]
    end
  end

  describe "GET /api/v1/apps/verify_credentials" do
    test "describes the app behind the token", %{conn: conn} do
      {application, _secret} = app_fixture()
      {:ok, _token, raw} = OAuth.issue_client_credentials_token(application, ["read"])

      body =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> get(~p"/api/v1/apps/verify_credentials")
        |> json_response(200)

      assert body["name"] == "Test Client"
      assert body["vapid_key"]
    end

    test "refuses without a token", %{conn: conn} do
      assert conn |> get(~p"/api/v1/apps/verify_credentials") |> json_response(401)
    end

    test "refuses a revoked token", %{conn: conn} do
      {application, _secret} = app_fixture()
      {:ok, token, raw} = OAuth.issue_client_credentials_token(application, ["read"])
      :ok = OAuth.revoke_token(token)

      assert conn
             |> put_req_header("authorization", "Bearer #{raw}")
             |> get(~p"/api/v1/apps/verify_credentials")
             |> json_response(401)
    end
  end
end
