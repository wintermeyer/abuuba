defmodule Abuuba.Repo.Migrations.CreatePollsPinsAndScheduledStatuses do
  @moduledoc """
  What the statuses API needs and the schema did not have yet.

  Five tables, each for something a client can already ask for.
  """
  use Ecto.Migration

  import Abuuba.Snowflake.Migration

  def change do
    ## Polls

    # One row per poll, options as an array rather than a table. They are only
    # ever read together with the poll and never queried on their own, so a
    # second table would buy a join and nothing else. The tallies live here too
    # for the same reason: every render needs them, and counting votes on each
    # render is a query per poll on every timeline.
    create table(:polls, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :status_id, references(:statuses, type: :bigint, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :options, {:array, :text}, null: false, default: []
      add :tallies, {:array, :integer}, null: false, default: []

      add :expires_at, :utc_datetime_usec
      add :multiple, :boolean, null: false, default: false
      # Distinct people, which is not the sum of the tallies once a poll allows
      # more than one answer.
      add :voters_count, :integer, null: false, default: 0

      # A poll on a remote post is somebody else's tally, refreshed by fetching
      # it rather than by counting rows here.
      add :uri, :string
      add :last_fetched_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:polls)
    create unique_index(:polls, [:status_id])
    create index(:polls, [:expires_at], where: "expires_at IS NOT NULL")

    create table(:poll_votes, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :poll_id, references(:polls, type: :bigint, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false
      add :choice, :integer, null: false
      add :uri, :string

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:poll_votes)

    # One vote per choice per person. A poll that allows several answers allows
    # several rows; it does not allow the same answer twice.
    create unique_index(:poll_votes, [:poll_id, :account_id, :choice])
    create index(:poll_votes, [:account_id])

    ## Pinned posts

    create table(:status_pins, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false
      add :status_id, references(:statuses, type: :bigint, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:status_pins)
    create unique_index(:status_pins, [:account_id, :status_id])

    ## Muted threads

    # Keyed by the conversation rather than by the status, because muting a
    # thread has to cover the replies nobody has written yet. Keyed on a status
    # one could only ever mute the past.
    create table(:conversation_mutes) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :conversation_id, references(:conversations, type: :bigint, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:conversation_mutes, [:account_id, :conversation_id])

    ## Scheduled posts

    # The whole request, kept as it arrived. Storing a half-built status row
    # instead would mean every query for a real post has to remember to exclude
    # posts that are not posts yet, and one that forgets publishes a draft.
    create table(:scheduled_statuses, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false
      add :scheduled_at, :utc_datetime_usec, null: false
      add :params, :map, null: false, default: %{}
      add :media_attachment_ids, {:array, :bigint}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:scheduled_statuses)
    create index(:scheduled_statuses, [:account_id, :scheduled_at])
    create index(:scheduled_statuses, [:scheduled_at])

    ## Idempotency

    # A client that times out while posting retries, and without this the retry
    # is a second post. Keyed per account so one client's key cannot collide
    # with another's, and swept rather than kept: the window only has to cover
    # a retry, not a history.
    create table(:idempotency_keys, primary_key: false) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :key, :string, null: false, primary_key: true
      add :status_id, references(:statuses, type: :bigint, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:idempotency_keys, [:inserted_at])
  end
end
