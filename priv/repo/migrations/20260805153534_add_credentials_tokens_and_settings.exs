defmodule Abuuba.Repo.Migrations.AddCredentialsTokensAndSettings do
  @moduledoc """
  What signing in needs: a password, tokens, and the instance's own settings.

  Tokens are stored hashed. A session token is a bearer credential, so a
  database leak that handed over the raw values would let the reader sign in as
  anybody without ever knowing a password. Hashing them means a leak yields
  only what the tokens hash to, which is worth nothing to a cookie.

  `sent_to` records the address a confirmation was sent to. Without it, somebody
  could request a confirmation, change their email, and then use the old link to
  confirm an address they never proved they own.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :hashed_password, :string
      add :confirmation_sent_at, :utc_datetime_usec

      # Set when a moderator approves a pending registration, so the decision
      # has an audit trail rather than a boolean that says nothing about when.
      add :approved_at, :utc_datetime_usec
    end

    create table(:user_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:user_tokens, [:context, :token])
    create index(:user_tokens, [:user_id])

    # Key/value rather than a wide singleton row, so that adding a setting is
    # not a migration. Values are jsonb so a setting can be a list (the server
    # rules) as easily as a string (the registration mode).
    create table(:instance_settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create table(:server_rules) do
      add :text, :text, null: false
      add :hint, :text, null: false, default: ""

      # Rules are shown in a deliberate order: a reader stops partway through a
      # list, so what comes first has to be what matters most.
      add :position, :integer, null: false, default: 0
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:server_rules, [:position], where: "deleted_at IS NULL")
  end
end
