defmodule Abuuba.Repo.Migrations.CreateEmojisAnnouncementsAndTags do
  @moduledoc """
  Custom emoji, server announcements, and the tags somebody follows.
  """
  use Ecto.Migration

  import Abuuba.Snowflake.Migration

  def change do
    # A shortcode is unique per domain rather than globally: two servers both
    # having a `:blobcat:` is the ordinary case, and a global unique index
    # would make the second one we heard of unstorable.
    create table(:custom_emojis, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :shortcode, :string, null: false
      add :domain, :string
      add :image_url, :string, null: false
      add :static_url, :string

      add :visible_in_picker, :boolean, null: false, default: true
      add :disabled, :boolean, null: false, default: false
      add :category, :string

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:custom_emojis)

    create unique_index(:custom_emojis, ["shortcode", "coalesce(domain, '')"],
             name: :custom_emojis_shortcode_domain_index
           )

    create index(:custom_emojis, [:domain])

    create table(:announcements, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :text, :text, null: false
      add :published, :boolean, null: false, default: false
      add :all_day, :boolean, null: false, default: false

      add :starts_at, :utc_datetime_usec
      add :ends_at, :utc_datetime_usec
      add :published_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:announcements)
    create index(:announcements, [:published, :id])

    # Per account, because an announcement everybody dismissed at once would
    # be an announcement nobody could still be reading.
    create table(:announcement_dismissals, primary_key: false) do
      add :announcement_id, references(:announcements, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true

      timestamps(type: :utc_datetime_usec)
    end

    create table(:announcement_reactions, primary_key: false) do
      add :announcement_id, references(:announcements, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :name, :string, null: false, primary_key: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:announcement_reactions, [:announcement_id, :name])

    # Following a tag puts its posts in a home timeline, which is why it is a
    # relationship rather than a bookmark.
    create table(:tag_follows, primary_key: false) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :tag_id, references(:tags, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tag_follows, [:tag_id])
  end
end
