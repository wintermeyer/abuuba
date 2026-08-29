defmodule Abuuba.Repo.Migrations.CreateOauth do
  @moduledoc """
  The OAuth2 provider tables.

  Shaped after Mastodon's, because every third-party client was written against
  those semantics, and a client that has to special-case this server is a
  client that will not bother.

  Access tokens do not expire and there are no refresh tokens. That is not an
  oversight to fix later: apps hold a token for years, and issuing an expiry
  they do not know to renew would sign everybody out of every client at once.
  Revoking is how a token ends.

  Secrets and tokens are stored hashed. A token is a bearer credential, so a
  database leak that handed over the raw values would let the reader act as
  every user of every app at once.
  """
  use Ecto.Migration

  def change do
    create table(:oauth_applications) do
      add :name, :string, null: false
      add :website, :text

      add :client_id, :string, null: false
      add :hashed_client_secret, :string, null: false

      # Several are allowed, newline separated, which is what the spec says and
      # what a client needs when it supports both a custom scheme and a web
      # callback.
      add :redirect_uris, :text, null: false, default: ""
      add :scopes, :string, null: false, default: "read"

      # Handed to clients so they can subscribe to Web Push. Public by design.
      add :vapid_key, :text

      # An application registered by a person rather than by an admin, so that
      # it can be listed and revoked in that person's settings.
      add :owner_user_id, references(:users, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oauth_applications, [:client_id])
    create index(:oauth_applications, [:owner_user_id])

    create table(:oauth_authorization_codes) do
      add :application_id, references(:oauth_applications, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :hashed_code, :string, null: false
      add :redirect_uri, :text, null: false
      add :scopes, :string, null: false

      # S256 only. `plain` puts the verifier itself in the authorize request,
      # so anybody who can see that request can complete the exchange, which is
      # the whole thing PKCE exists to prevent.
      add :code_challenge, :string
      add :code_challenge_method, :string

      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:oauth_authorization_codes, [:hashed_code])
    create index(:oauth_authorization_codes, [:application_id, :user_id])

    create table(:oauth_access_tokens) do
      add :application_id, references(:oauth_applications, on_delete: :delete_all), null: false

      # Null for a client_credentials token, which acts for the app itself
      # rather than on anybody's behalf.
      add :user_id, references(:users, on_delete: :delete_all)

      add :hashed_token, :string, null: false
      add :scopes, :string, null: false

      add :revoked_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:oauth_access_tokens, [:hashed_token])
    create index(:oauth_access_tokens, [:user_id])

    # Re-authorising the same app for the same user with the same scopes hands
    # back the token it already has, which is what Mastodon does and what
    # clients rely on. Without it every re-authorisation would strand the
    # previous token and the list of authorised apps would fill with duplicates.
    create unique_index(:oauth_access_tokens, [:application_id, :user_id, :scopes],
             where: "revoked_at IS NULL AND user_id IS NOT NULL",
             name: :oauth_access_tokens_one_live_per_app_user_scope
           )
  end
end
