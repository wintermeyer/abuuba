defmodule Abuuba.Repo.Migrations.CreateRelationshipsAndStats do
  @moduledoc """
  The follow graph, the things that suppress parts of it, and two counter
  sidecars.

  Every edge table carries the same pair of indexes: one on
  `(account_id, target_account_id)` to answer "does A follow B", and the
  reverse to answer "who follows B". Both questions are asked constantly and
  neither can be served by the other's index.

  `follows` and `follow_requests` have the same shape on purpose. Accepting a
  request moves a row from one table to the other, so a column that exists on
  one has to exist on the other, or the settings chosen at request time are
  quietly lost at the moment of acceptance.

  The two `*_stats` tables exist so that a favourite does not write to the
  status row itself. Counters are the hottest columns in the schema and the
  status row is the widest; keeping them apart means a burst of favourites does
  not rewrite the text of a post over and over, and does not contend with an
  edit to it.
  """
  use Ecto.Migration

  def change do
    for table <- [:follows, :follow_requests] do
      create table(table) do
        add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

        add :target_account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
          null: false

        # Whether the follower wants this account's boosts in their timeline,
        # and whether they want a notification for every post.
        add :show_reblogs, :boolean, null: false, default: true
        add :notify, :boolean, null: false, default: false

        # Null or empty means every language. A per-follow filter rather than a
        # global one, because somebody may want one account's German posts and
        # another's English ones.
        add :languages, {:array, :string}

        add :uri, :text

        timestamps(type: :utc_datetime_usec)
      end

      create unique_index(table, [:account_id, :target_account_id])
      create index(table, [:target_account_id, :account_id])
      create unique_index(table, [:uri])

      create constraint(table, :"#{table}_no_self_reference",
               check: "account_id <> target_account_id"
             )
    end

    create table(:blocks) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :target_account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false

      add :uri, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:blocks, [:account_id, :target_account_id])
    create index(:blocks, [:target_account_id, :account_id])

    create constraint(:blocks, :blocks_no_self_reference,
             check: "account_id <> target_account_id"
           )

    create table(:mutes) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :target_account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false

      # A mute hides posts. Whether it also hides notifications is a separate
      # choice: muting a loud account is not the same as wanting to miss it
      # replying to you.
      add :hide_notifications, :boolean, null: false, default: true

      # Null means indefinitely.
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mutes, [:account_id, :target_account_id])
    create index(:mutes, [:target_account_id, :account_id])
    create index(:mutes, [:expires_at], where: "expires_at IS NOT NULL")

    create constraint(:mutes, :mutes_no_self_reference, check: "account_id <> target_account_id")

    # A personal block on a whole server, distinct from the instance-wide
    # domain blocks a moderator sets.
    create table(:account_domain_blocks) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false
      add :domain, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:account_domain_blocks, [:account_id, :domain])

    # A private note one account keeps about another, shown only to its author.
    create table(:account_notes) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :target_account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false

      add :comment, :text, null: false, default: ""

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:account_notes, [:account_id, :target_account_id])

    # Keyed by the parent's id rather than carrying an id of their own, so the
    # lookup is the primary key and a row can be upserted by that key alone.
    create table(:account_stats, primary_key: false) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :statuses_count, :bigint, null: false, default: 0
      add :following_count, :bigint, null: false, default: 0
      add :followers_count, :bigint, null: false, default: 0
      add :last_status_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create table(:status_stats, primary_key: false) do
      add :status_id, references(:statuses, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :replies_count, :bigint, null: false, default: 0
      add :reblogs_count, :bigint, null: false, default: 0
      add :favourites_count, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    # A counter that has gone negative is a bug in whoever decremented it, and
    # it renders as a nonsense number on somebody's profile. Catch it at source.
    create constraint(:account_stats, :account_stats_counts_are_not_negative,
             check: "statuses_count >= 0 AND following_count >= 0 AND followers_count >= 0"
           )

    create constraint(:status_stats, :status_stats_counts_are_not_negative,
             check: "replies_count >= 0 AND reblogs_count >= 0 AND favourites_count >= 0"
           )
  end
end
