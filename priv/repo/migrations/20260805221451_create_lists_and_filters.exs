defmodule Abuuba.Repo.Migrations.CreateListsAndFilters do
  @moduledoc """
  Lists, and the filters that keep words out of somebody's timelines.

  ## Why a filter is three tables

  One filter, many keywords, many exempted posts. A person writes one rule
  ("hide anything about the election, in my home timeline, until Tuesday") and
  gives it several spellings. Flattening that into one row per keyword would
  mean the expiry, the action and the contexts repeated on every one of them,
  and changing the rule would mean finding and changing all of them together.
  """
  use Ecto.Migration

  import Abuuba.Snowflake.Migration

  def change do
    create table(:lists, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false
      add :title, :string, null: false

      # Which replies from list members belong in it. "Somebody I follow" is
      # the useful middle: a list about cycling should carry a member's reply
      # to another cyclist and not their reply to a stranger.
      add :replies_policy, :string, null: false, default: "list"

      # An exclusive list takes its members out of the home timeline entirely,
      # which is what makes a list a way of reading less rather than more.
      add :exclusive, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:lists)
    create index(:lists, [:account_id])
    create unique_index(:lists, [:account_id, :title])

    create table(:list_accounts, primary_key: false) do
      add :list_id, references(:lists, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:list_accounts, [:account_id])

    create table(:filters, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false
      add :title, :string, null: false

      # Where it applies: home, notifications, public, thread, account.
      add :context, {:array, :string}, null: false, default: []

      # `warn` folds the post away behind the filter's name, which is what
      # somebody wants for a topic they mostly avoid. `hide` removes it, which
      # is what they want for one they never wish to see.
      add :filter_action, :string, null: false, default: "warn"

      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:filters)
    create index(:filters, [:account_id])
    create index(:filters, [:expires_at], where: "expires_at IS NOT NULL")

    create table(:filter_keywords, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :filter_id, references(:filters, type: :bigint, on_delete: :delete_all), null: false
      add :keyword, :string, null: false

      # Whether "cat" should match "concatenate". Almost never, which is why a
      # client offers the choice.
      add :whole_word, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:filter_keywords)
    create index(:filter_keywords, [:filter_id])

    # One post exempted from, or caught by, a filter by hand.
    create table(:filter_statuses, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :filter_id, references(:filters, type: :bigint, on_delete: :delete_all), null: false
      add :status_id, references(:statuses, type: :bigint, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:filter_statuses)
    create unique_index(:filter_statuses, [:filter_id, :status_id])
  end
end
