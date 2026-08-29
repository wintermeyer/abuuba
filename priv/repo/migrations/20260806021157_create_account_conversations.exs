defmodule Abuuba.Repo.Migrations.CreateAccountConversations do
  use Ecto.Migration

  import Abuuba.Snowflake.Migration

  @moduledoc """
  One row per person per conversation they are in.

  ## Why one row each rather than one per conversation

  A conversation is shared, but the state around it is not: whether it has been
  read, whether it has been muted, and whether somebody has removed it from
  their own inbox are all one person's answers. Storing them on the
  conversation would mean one person marking a thread read marks it read for
  everybody in it.

  ## The participant set is part of the identity

  A group message to three people and a private one to a single person can sit
  in the same conversation. They are different threads to the person reading
  them, so the row is keyed by who is in it as well as which conversation it
  is. That is what the array in the unique index is for.

  ## The status ids live here

  Reading an inbox means "the last message in each thread, newest thread
  first", and this table answers it directly. The array is what a client uses
  to fetch the thread without a second query against every status in it.
  """

  def change do
    create table(:account_conversations, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :conversation_id,
          references(:conversations, type: :bigint, on_delete: :delete_all),
          null: false

      # Everybody in the thread except its owner, sorted, so the same set of
      # people always produces the same key.
      add :participant_account_ids, {:array, :bigint}, null: false, default: []
      add :status_ids, {:array, :bigint}, null: false, default: []
      add :last_status_id, :bigint

      add :unread, :boolean, null: false, default: false
      add :muted, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:account_conversations)

    # The identity, and what makes a concurrent delivery an upsert rather than
    # a duplicate: two messages arriving at once for the same thread find the
    # same row.
    create unique_index(
             :account_conversations,
             [:account_id, :conversation_id, :participant_account_ids],
             name: :account_conversations_identity
           )

    # The read: one person's inbox, newest activity first, seeking by cursor.
    create index(:account_conversations, [:account_id, "last_status_id DESC"],
             name: :account_conversations_reading_index
           )
  end
end
