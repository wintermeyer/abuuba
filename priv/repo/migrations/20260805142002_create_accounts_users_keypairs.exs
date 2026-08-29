defmodule Abuuba.Repo.Migrations.CreateAccountsUsersKeypairs do
  @moduledoc """
  The three tables every other table will point at.

  `accounts` holds actors, local and remote alike, in one table. An account is
  local exactly when `domain IS NULL`. Keeping remote actors in the same table
  is what lets a follow, a mention or a block be one foreign key instead of a
  polymorphic pair, and it is the shape the client API already assumes.

  `users` carries what only a local account has: an email address, a locale,
  and the state of its registration. Splitting it off keeps credentials out of
  the row that federation serialises and hands to other servers.

  `keypairs` holds signing keys. It is a table rather than two columns on
  `accounts` because a key has a lifecycle of its own: it can be rotated,
  revoked, or expire, and a second algorithm is coming.
  """
  use Ecto.Migration

  import Abuuba.Snowflake.Migration

  def change do
    create table(:accounts, primary_key: false) do
      add :id, :bigint, primary_key: true

      # Local iff domain IS NULL. The pair is what makes an actor unique, and
      # both halves are compared case-insensitively: @Alice@Example.com and
      # @alice@example.com are the same person everywhere on the fediverse.
      add :username, :string, null: false
      add :domain, :string

      add :actor_type, :string, null: false, default: "Person"
      add :display_name, :string, null: false, default: ""
      add :note, :text, null: false, default: ""

      # ActivityPub endpoints. `uri` is the actor id other servers use to name
      # this account; `url` is the human-facing profile page.
      add :uri, :text
      add :url, :text
      add :inbox_url, :text
      add :shared_inbox_url, :text
      add :outbox_url, :text
      add :followers_url, :text
      add :following_url, :text

      # Profile metadata rows, at most four, each a name and a value.
      add :fields, :map, null: false, default: fragment("'[]'::jsonb")

      # Moderation state as timestamps, not booleans: a moderator needs to know
      # when an account was suspended as much as whether it is, and a nullable
      # timestamp cannot drift out of sync with a separate "when" column.
      add :suspended_at, :utc_datetime_usec
      add :silenced_at, :utc_datetime_usec
      add :sensitized_at, :utc_datetime_usec

      add :moved_to_account_id, references(:accounts, type: :bigint, on_delete: :nilify_all)
      add :also_known_as, {:array, :text}, null: false, default: []

      add :locked, :boolean, null: false, default: false
      add :bot, :boolean, null: false, default: false
      add :discoverable, :boolean, null: false, default: false
      add :indexable, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:accounts)

    # One actor per name per host. `coalesce(lower(domain), '')` rather than
    # lower(domain): a plain unique index over a nullable column would let two
    # local accounts share a username, because in SQL NULL never equals NULL.
    create unique_index(:accounts, ["lower(username)", "coalesce(lower(domain), '')"],
             name: :accounts_username_domain_index
           )

    create index(:accounts, [:domain])
    create index(:accounts, [:moved_to_account_id])

    # Ids below zero are reserved for actors abuuba creates for itself, such as
    # the instance actor that signs server-to-server requests. timestamp_id
    # only ever mints positive ids, so the two ranges cannot meet. Such an
    # actor is always local, and this makes that structural.
    create constraint(:accounts, :accounts_internal_actors_are_local,
             check: "id > 0 OR domain IS NULL"
           )

    create constraint(:accounts, :accounts_at_most_four_fields,
             check: "jsonb_array_length(fields) <= 4"
           )

    # NULL means local; an empty string would mean "hosted on the server named
    # nothing", which no query matches while it still occupies the local slot
    # in the unique index above. The changeset normalises it away, and this
    # holds if some later code path writes the row without one.
    create constraint(:accounts, :accounts_domain_is_null_or_present,
             check: "domain IS NULL OR domain <> ''"
           )

    create table(:users) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :email, :string, null: false
      add :confirmed_at, :utc_datetime_usec
      add :approved, :boolean, null: false, default: false
      add :locale, :string
      add :settings, :map, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:account_id])
    create unique_index(:users, ["lower(email)"], name: :users_email_index)

    create table(:keypairs) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :type, :string, null: false, default: "rsa_2048"
      add :public_key, :text, null: false

      # Encrypted by Abuuba.Vault, hence bytea rather than text. Null where we
      # hold only the public half, which is the case for every remote actor.
      add :private_key, :binary

      add :revoked_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:keypairs, [:account_id])

    # The key an account signs with right now. Rotation revokes the old row
    # before inserting the new one, so at most one is ever live.
    create unique_index(:keypairs, [:account_id],
             where: "revoked_at IS NULL AND private_key IS NOT NULL",
             name: :keypairs_one_active_private_key_per_account
           )
  end
end
