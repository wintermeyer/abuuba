defmodule Abuuba.Repo.Migrations.CreateDomainBlocksAndSeverance do
  use Ecto.Migration

  @moduledoc """
  Refusing whole servers, and the honest record of what that cost.

  ## A block has a severity rather than being on or off

  Silencing a domain leaves its people reachable by the local accounts who
  chose to follow them and takes them out of everywhere nobody chose.
  Suspending one cuts it off. "Nothing" is a real severity too: a row that only
  sets `reject_media` or `reject_reports` is a real decision and needs
  somewhere to live.

  ## Severance is recorded because somebody lost something

  Suspending a domain deletes follow relationships that people spent years
  building, and the accounts on the other side cannot be asked. Recording which
  relationships went, and telling the local accounts that lost them, is the
  difference between a moderation decision and a pile of followers silently
  vanishing overnight.

  ## Allows are a separate table

  A server in allowlist mode federates with the domains in `domain_allows` and
  nowhere else. Kept apart from blocks because "not on the allowlist" is not a
  moderation decision about that server, it is the absence of one, and folding
  the two together would make an empty allowlist read as a thousand blocks.
  """

  def change do
    create table(:domain_blocks) do
      add :domain, :string, null: false
      add :severity, :string, null: false, default: "silence"
      add :reject_media, :boolean, null: false, default: false
      add :reject_reports, :boolean, null: false, default: false
      # Shown to anybody reading the server's list of blocks. Deliberately
      # separate from the private one: an admin has to be able to write down
      # why without publishing it.
      add :public_comment, :text
      add :private_comment, :text
      # Publishes the domain with its middle replaced by asterisks. For the
      # cases where naming a server in full invites its users to come and
      # argue about it.
      add :obfuscate, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:domain_blocks, [:domain])

    create constraint(:domain_blocks, :domain_blocks_severity_known,
             check: "severity in ('noop', 'silence', 'suspend')"
           )

    create table(:domain_allows) do
      add :domain, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:domain_allows, [:domain])

    create table(:relationship_severance_events) do
      add :type, :string, null: false
      # The domain or handle it was about, kept as text: the block it names may
      # be lifted later and the record still has to say what happened.
      add :target_name, :string, null: false
      add :purged, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create table(:severed_relationships) do
      add :relationship_severance_event_id,
          references(:relationship_severance_events, on_delete: :delete_all),
          null: false

      add :local_account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false

      add :remote_account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false

      # "active" is the local account following the remote one, "passive" the
      # other way around. Both are lost and they read differently to the person
      # who lost them.
      add :direction, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :severed_relationships,
             [
               :relationship_severance_event_id,
               :local_account_id,
               :remote_account_id,
               :direction
             ],
             name: :severed_relationships_one_per_edge
           )

    # The page somebody reads about their own losses, newest event first.
    create index(:severed_relationships, [:local_account_id, :relationship_severance_event_id])

    create constraint(:severed_relationships, :severed_relationships_direction_known,
             check: "direction in ('active', 'passive')"
           )

    # Delivery this server stopped on purpose, as opposed to a domain it gave
    # up on after a week of failures. Kept apart because an inbound request
    # clears the latter and must not clear the former: an admin who stopped
    # delivering did not mean "until they say something".
    alter table(:instance_availability) do
      add :stopped_at, :utc_datetime_usec
    end
  end
end
