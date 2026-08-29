defmodule Abuuba.OAuthTest do
  use Abuuba.DataCase, async: true

  alias Abuuba.Accounts.Auth
  alias Abuuba.OAuth
  alias Abuuba.OAuth.AccessToken
  alias Abuuba.OAuth.Scopes
  alias Abuuba.Settings
  alias Abuuba.Streaming

  setup do
    Settings.put_registration_mode(:open)

    {:ok, %{user: user}} =
      Auth.register(
        %{
          "username" => "alice",
          "email" => "alice@example.com",
          "password" => "correct horse battery"
        },
        rules_required: false
      )

    {:ok, application, secret} =
      OAuth.create_application(%{
        name: "Test Client",
        redirect_uris: "https://app.example/callback",
        scopes: "read write follow"
      })

    %{user: user, application: application, secret: secret}
  end

  describe "the scope tree" do
    test "a parent covers its children, and not the other way round" do
      assert Scopes.covers?(["read"], "read:statuses")
      assert Scopes.covers?(["admin:read"], "admin:read:accounts")

      refute Scopes.covers?(["read:statuses"], "read")
      refute Scopes.covers?(["read"], "write")
      refute Scopes.covers?(["read"], "write:statuses")
    end

    test "does not treat a prefix as an ancestor" do
      # `read` must not cover `readonly:something`, which shares its letters
      # but not its place in the tree.
      refute Scopes.covers?(["read"], "readsomething")
    end

    test "refuses a scope it does not know rather than dropping it" do
      assert {:error, ["fly"]} = Scopes.parse("read fly")
      assert {:ok, ["read", "write:statuses"]} = Scopes.parse("read write:statuses")
    end

    test "defaults to read when nothing is asked for" do
      assert Scopes.parse(nil) == {:ok, ["read"]}
      assert Scopes.parse("") == {:ok, ["read"]}
    end

    test "canonicalises order, so the same request is the same token" do
      assert Scopes.to_string(["write", "read"]) == "read write"
      assert Scopes.to_string(["read", "write"]) == "read write"
    end

    test "an app cannot be granted more than it registered for" do
      assert Scopes.narrow(["read", "write", "admin:read"], "read write") == ["read", "write"]
      assert Scopes.narrow(["write:statuses"], "read") == []
    end
  end

  describe "applications" do
    test "hand back the secret once and store only its hash", %{
      application: application,
      secret: secret
    } do
      assert OAuth.valid_client_secret?(application, secret)
      refute OAuth.valid_client_secret?(application, "wrong")
      refute application.hashed_client_secret == secret
    end

    test "match a redirect URI exactly, never by prefix", %{application: application} do
      alias Abuuba.OAuth.Application, as: App

      assert App.registered_redirect_uri?(application, "https://app.example/callback")

      refute App.registered_redirect_uri?(
               application,
               "https://app.example/callback.evil.example"
             ),
             "a prefix match here is how authorization codes get stolen"

      refute App.registered_redirect_uri?(application, "https://app.example/callback/../x")
    end

    test "accept the custom schemes mobile clients use" do
      assert {:ok, _app, _secret} =
               OAuth.create_application(%{name: "Mobile", redirect_uris: "myapp://oauth"})
    end

    test "refuse a redirect URI that is not one" do
      assert {:error, changeset} =
               OAuth.create_application(%{name: "Bad", redirect_uris: "not a uri"})

      assert errors_on(changeset).redirect_uris != []
    end

    test "refuse a scope this server does not know" do
      assert {:error, changeset} =
               OAuth.create_application(%{
                 name: "Greedy",
                 redirect_uris: "https://a.example/cb",
                 scopes: "read fly"
               })

      assert errors_on(changeset).scopes != []
    end
  end

  describe "the authorization code flow" do
    test "issues a token for the right code", %{application: application, user: user} do
      {:ok, code} =
        OAuth.create_authorization_code(application, user,
          redirect_uri: "https://app.example/callback",
          scopes: ["read"]
        )

      assert {:ok, token, raw} =
               OAuth.exchange_authorization_code(code,
                 application: application,
                 redirect_uri: "https://app.example/callback"
               )

      assert token.scopes == "read"
      assert OAuth.get_token(raw).id == token.id
    end

    test "a code works exactly once", %{application: application, user: user} do
      {:ok, code} =
        OAuth.create_authorization_code(application, user,
          redirect_uri: "https://app.example/callback",
          scopes: ["read"]
        )

      {:ok, _token, _raw} =
        OAuth.exchange_authorization_code(code, application: application)

      assert OAuth.exchange_authorization_code(code, application: application) ==
               {:error, :invalid_grant}
    end

    test "a code belongs to the application it was issued to", %{
      application: application,
      user: user
    } do
      {:ok, other, _secret} =
        OAuth.create_application(%{name: "Other", redirect_uris: "https://other.example/cb"})

      {:ok, code} =
        OAuth.create_authorization_code(application, user,
          redirect_uri: "https://app.example/callback",
          scopes: ["read"]
        )

      assert OAuth.exchange_authorization_code(code, application: other) ==
               {:error, :invalid_client}
    end

    test "a code cannot be redeemed against a different callback", %{
      application: application,
      user: user
    } do
      {:ok, code} =
        OAuth.create_authorization_code(application, user,
          redirect_uri: "https://app.example/callback",
          scopes: ["read"]
        )

      assert OAuth.exchange_authorization_code(code,
               application: application,
               redirect_uri: "https://attacker.example/cb"
             ) == {:error, :invalid_grant}
    end

    test "a code cannot be issued for an unregistered callback", %{
      application: application,
      user: user
    } do
      assert OAuth.create_authorization_code(application, user,
               redirect_uri: "https://attacker.example/cb",
               scopes: ["read"]
             ) == {:error, :invalid_redirect_uri}
    end

    test "an expired code is refused", %{application: application, user: user} do
      {:ok, code} =
        OAuth.create_authorization_code(application, user,
          redirect_uri: "https://app.example/callback",
          scopes: ["read"]
        )

      Repo.update_all(Abuuba.OAuth.AuthorizationCode,
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
      )

      assert OAuth.exchange_authorization_code(code, application: application) ==
               {:error, :invalid_grant}
    end
  end

  describe "PKCE" do
    setup %{application: application, user: user} do
      verifier = "a-verifier-long-enough-to-be-worth-something"
      challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

      {:ok, code} =
        OAuth.create_authorization_code(application, user,
          redirect_uri: "https://app.example/callback",
          scopes: ["read"],
          code_challenge: challenge,
          code_challenge_method: "S256"
        )

      %{code: code, verifier: verifier}
    end

    test "the right verifier completes the exchange", %{
      application: application,
      code: code,
      verifier: verifier
    } do
      assert {:ok, _token, _raw} =
               OAuth.exchange_authorization_code(code,
                 application: application,
                 code_verifier: verifier
               )
    end

    test "a wrong verifier does not", %{application: application, code: code} do
      assert OAuth.exchange_authorization_code(code,
               application: application,
               code_verifier: "not it"
             ) == {:error, :invalid_verifier}
    end

    test "a missing verifier does not", %{application: application, code: code} do
      assert OAuth.exchange_authorization_code(code, application: application) ==
               {:error, :invalid_verifier}
    end

    test "plain is refused outright", %{application: application, user: user} do
      # `plain` puts the verifier in the authorize request, so anybody who can
      # read that request can finish the exchange.
      assert OAuth.create_authorization_code(application, user,
               redirect_uri: "https://app.example/callback",
               scopes: ["read"],
               code_challenge: "anything",
               code_challenge_method: "plain"
             ) == {:error, :unsupported_challenge_method}
    end
  end

  describe "tokens" do
    test "do not expire and have no refresh token", %{application: application, user: user} do
      {:ok, token, _raw} = OAuth.issue_token(application, user, ["read"])

      assert AccessToken.live?(token)
      refute Map.has_key?(token, :expires_at)
    end

    test "re-authorising the same app and scopes reuses the row", %{
      application: application,
      user: user
    } do
      {:ok, first, _} = OAuth.issue_token(application, user, ["read"])
      {:ok, second, _} = OAuth.issue_token(application, user, ["read"])

      assert first.id == second.id,
             "a second row would strand the first and duplicate the app in the authorised list"
    end

    test "different scopes are a different token", %{application: application, user: user} do
      {:ok, read, _} = OAuth.issue_token(application, user, ["read"])
      {:ok, write, _} = OAuth.issue_token(application, user, ["write"])

      refute read.id == write.id
    end

    test "are stored hashed", %{application: application, user: user} do
      {:ok, token, raw} = OAuth.issue_token(application, user, ["read"])

      refute token.hashed_token == raw
      assert OAuth.get_token(raw).id == token.id
    end

    test "a client_credentials token acts for nobody", %{application: application} do
      {:ok, token, _raw} = OAuth.issue_client_credentials_token(application, ["read"])

      assert AccessToken.app_only?(token)
      assert token.user_id == nil
    end

    test "revoking makes the token stop working", %{application: application, user: user} do
      {:ok, token, raw} = OAuth.issue_token(application, user, ["read"])

      :ok = OAuth.revoke_token(token)

      assert OAuth.get_token(raw) == nil
    end

    test "a client can only revoke its own tokens", %{application: application, user: user} do
      {:ok, other, _secret} =
        OAuth.create_application(%{name: "Other", redirect_uris: "https://other.example/cb"})

      {:ok, _token, raw} = OAuth.issue_token(application, user, ["read"])

      :ok = OAuth.revoke_presented_token(other, raw)

      assert OAuth.get_token(raw), "another app must not be able to revoke this one's token"

      :ok = OAuth.revoke_presented_token(application, raw)
      refute OAuth.get_token(raw)
    end

    test "revoking a token that does not exist is still a success", %{application: application} do
      # RFC 7009. Otherwise the endpoint tells an attacker whether a token
      # is valid.
      assert OAuth.revoke_presented_token(application, "not a token") == :ok
    end

    test "nonsense is not a token" do
      assert OAuth.get_token("nope") == nil
      assert OAuth.get_token(nil) == nil
    end

    test "list the applications a person has authorised", %{
      application: application,
      user: user
    } do
      {:ok, _token, _raw} = OAuth.issue_token(application, user, ["read"])

      assert [{listed, ["read"]}] = OAuth.authorized_applications(user)
      assert listed.id == application.id
    end

    test "list one entry per application, whatever it may do through either token", %{
      application: application,
      user: user
    } do
      {:ok, _token, _raw} = OAuth.issue_token(application, user, ["read:statuses"])
      {:ok, _second, _raw} = OAuth.issue_token(application, user, ["write:media"])

      # An app signed in twice is one app. The answer to "what may it do" is
      # everything either token carries: one token's scopes would understate
      # what it can reach, and two rows would ask the reader to work out that
      # they are the same app.
      assert [{listed, scopes}] = OAuth.authorized_applications(user)
      assert listed.id == application.id
      assert Enum.sort(scopes) == ["read:statuses", "write:media"]
    end

    test "leave a revoked token out", %{application: application, user: user} do
      {:ok, _token, _raw} = OAuth.issue_token(application, user, ["read"])
      :ok = OAuth.revoke_application_for(user, application.id)

      assert OAuth.authorized_applications(user) == []
    end
  end

  describe "revoking and the live stream" do
    test "one token closes its own connection", %{application: application, user: user} do
      # The socket authenticates once and never again, so a revoked token
      # keeps its stream until the client happens to disconnect. Every path
      # that revokes has to say so, not only the one that goes through
      # `revoke_token/1`.
      {:ok, token, _raw} = OAuth.issue_token(application, user, ["read"])

      :ok = Streaming.subscribe(Streaming.token_topic(token.id))
      :ok = OAuth.revoke_token(token)

      assert_receive {:streaming, :revoked}
    end

    test "revoking an application closes every connection it holds", %{
      application: application,
      user: user
    } do
      # `update_all` does not go through `revoke_token/1`, so this path had to
      # be told separately -- an app signed in twice would otherwise keep one
      # stream open after being signed out.
      {:ok, first, _raw} = OAuth.issue_token(application, user, ["read"])
      {:ok, second, _raw} = OAuth.issue_token(application, user, ["write"])

      :ok = Streaming.subscribe(Streaming.token_topic(first.id))
      :ok = Streaming.subscribe(Streaming.token_topic(second.id))

      :ok = OAuth.revoke_application_for(user, application.id)

      assert_receive {:streaming, :revoked}
      assert_receive {:streaming, :revoked}
    end

    test "and signing out everywhere closes all of them", %{
      application: application,
      user: user
    } do
      {:ok, token, _raw} = OAuth.issue_token(application, user, ["read"])

      :ok = Streaming.subscribe(Streaming.token_topic(token.id))
      :ok = OAuth.revoke_all_for(user)

      assert_receive {:streaming, :revoked}
    end
  end
end
