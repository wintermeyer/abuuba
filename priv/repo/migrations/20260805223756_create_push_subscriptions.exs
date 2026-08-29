defmodule Abuuba.Repo.Migrations.CreatePushSubscriptions do
  @moduledoc """
  Where a browser wants to be told about a notification.

  One per access token, not per account. A person has the same account on a
  phone and a laptop and expects both to buzz, and each of those is a different
  app holding a different token: keyed on the account, the second one to
  subscribe would silently replace the first and one of the two devices would
  go quiet with nothing to show why.
  """
  use Ecto.Migration

  import Abuuba.Snowflake.Migration

  def change do
    create table(:push_subscriptions, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :access_token_id,
          references(:oauth_access_tokens, type: :bigint, on_delete: :delete_all), null: false

      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      # Where the browser's push service wants the message.
      add :endpoint, :text, null: false

      # The subscriber's key and auth secret, which is what the payload is
      # encrypted to. Without them a push service will deliver an empty
      # notification and the browser will show "New message" and nothing else.
      add :key_p256dh, :string, null: false
      add :key_auth, :string, null: false

      # Which notification types this device wants, and from whom.
      add :alerts, :map, null: false, default: %{}
      add :policy, :string, null: false, default: "all"

      # aes128gcm is RFC 8291; aesgcm is what subscriptions made before it use,
      # and they keep working until the browser renews them.
      add :encoding, :string, null: false, default: "aes128gcm"

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:push_subscriptions)

    create unique_index(:push_subscriptions, [:access_token_id])
    create index(:push_subscriptions, [:account_id])
  end
end
