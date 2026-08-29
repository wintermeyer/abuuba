defmodule Abuuba.Repo.Migrations.CreateNotifications do
  @moduledoc """
  What somebody is told about, how it is grouped, and what they never see.

  ## Why a group key on the row

  Twenty people boosting one post is one thing that happened, and a client
  shows it as one line. Working the grouping out at read time means grouping
  the whole table on every request; deciding it once, when the notification is
  written, makes reading it a plain query.

  ## Why `filtered` is a column

  A notification from somebody the reader has never heard of goes to a separate
  inbox rather than into the main list. Whether it belongs there depends on the
  reader's policy and on the relationship at the moment it arrived, and
  recomputing that per read would mean the same notification moving between
  lists as relationships change. It is decided on the way in and stays decided.
  """
  use Ecto.Migration

  import Abuuba.Snowflake.Migration

  def change do
    create table(:notifications, primary_key: false) do
      add :id, :bigint, primary_key: true

      # Who is being told.
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false
      # Who caused it.
      add :from_account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false

      add :type, :string, null: false
      add :status_id, references(:statuses, type: :bigint, on_delete: :delete_all)

      # One line in a client for everything sharing it.
      add :group_key, :string, null: false
      add :filtered, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:notifications)

    create index(:notifications, [:account_id, :id])
    create index(:notifications, [:account_id, :type, :id])
    create index(:notifications, [:account_id, :group_key])
    create index(:notifications, [:account_id, :filtered, :id])
    create index(:notifications, [:from_account_id])

    # One notification per thing that happened. A boost delivered twice is one
    # boost, and the reader should be told once.
    create unique_index(:notifications, [:account_id, :from_account_id, :type, :status_id],
             where: "status_id IS NOT NULL",
             name: :notifications_one_per_event
           )

    # Six axes, each answering "what do I do about somebody like this": accept
    # it, file it under requests, or drop it. Stored per account because it is
    # a person's own decision about their own attention.
    create table(:notification_policies, primary_key: false) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :for_not_following, :string, null: false, default: "accept"
      add :for_not_followers, :string, null: false, default: "accept"
      add :for_new_accounts, :string, null: false, default: "accept"
      add :for_private_mentions, :string, null: false, default: "filter"
      add :for_limited_accounts, :string, null: false, default: "filter"
      add :for_bots, :string, null: false, default: "accept"

      timestamps(type: :utc_datetime_usec)
    end

    # One row per sender whose notifications were filtered, so the inbox is a
    # list of people rather than a list of events. Accepting one is a decision
    # about the person.
    create table(:notification_requests, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :from_account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false

      add :notifications_count, :integer, null: false, default: 0
      add :last_status_id, references(:statuses, type: :bigint, on_delete: :nilify_all)
      add :dismissed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:notification_requests)

    create unique_index(:notification_requests, [:account_id, :from_account_id])
    create index(:notification_requests, [:account_id, :dismissed_at])
  end
end
