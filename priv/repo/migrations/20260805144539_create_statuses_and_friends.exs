defmodule Abuuba.Repo.Migrations.CreateStatusesAndFriends do
  @moduledoc """
  Statuses and everything that hangs off one.

  Two shapes here are worth stating plainly, because both look like
  denormalisation gone wrong until you see the query they exist for.

  A boost is a status row of its own, pointing at the boosted status through
  `reblog_of_id`, rather than a separate table. It shares the statuses' id
  sequence, so a home timeline can return posts and boosts interleaved from one
  ordered scan without merging two sources. The public timeline below excludes
  boosts on purpose, which is a policy about that timeline rather than a
  consequence of the shape.

  `in_reply_to_account_id` duplicates a column reachable through
  `in_reply_to_id`. It is here because the public timeline shows a reply only
  when it is a reply to its own author, and a partial index cannot join. With
  the column present the predicate is local to the row and the index below can
  carry it.
  """
  use Ecto.Migration

  import Abuuba.Snowflake.Migration

  def change do
    create table(:conversations) do
      # Null for a conversation started here. A remote one carries the URI of
      # the thread's context, which is how replies from several servers are
      # gathered into the same conversation.
      add :uri, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:conversations, [:uri])

    create table(:statuses, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      # Null for a local status until it is first rendered for federation, so
      # this cannot be used to tell local from remote; `local` below can.
      add :uri, :text
      add :url, :text
      add :local, :boolean, null: false, default: true

      add :text, :text, null: false, default: ""
      add :spoiler_text, :text, null: false, default: ""
      add :language, :string
      add :sensitive, :boolean, null: false, default: false
      add :visibility, :string, null: false, default: "public"

      # Soft delete. A status has to outlive its own deletion for a while: a
      # Delete activity may still be in flight to other servers, and a boost or
      # a reply elsewhere may still point at it.
      add :deleted_at, :utc_datetime_usec
      add :edited_at, :utc_datetime_usec

      add :reblog_of_id, references(:statuses, type: :bigint, on_delete: :delete_all)
      add :in_reply_to_id, references(:statuses, type: :bigint, on_delete: :nilify_all)
      add :in_reply_to_account_id, references(:accounts, type: :bigint, on_delete: :nilify_all)
      add :conversation_id, references(:conversations, on_delete: :nilify_all)

      # The author's chosen order, which no join can reproduce.
      add :ordered_media_attachment_ids, {:array, :bigint}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:statuses)

    create unique_index(:statuses, [:uri])
    create index(:statuses, [:account_id, :id])
    create index(:statuses, [:in_reply_to_id])
    create index(:statuses, [:conversation_id])
    create index(:statuses, [:reblog_of_id])

    # One boost per account per status. A partial index because reblog_of_id is
    # null for an ordinary post, and those must not collide with each other.
    create unique_index(:statuses, [:account_id, :reblog_of_id],
             where: "reblog_of_id IS NOT NULL AND deleted_at IS NULL",
             name: :statuses_one_boost_per_account_index
           )

    create constraint(:statuses, :statuses_visibility_known,
             check: "visibility IN ('public', 'unlisted', 'private', 'direct', 'limited')"
           )

    # A boost carries no content of its own; it is a pointer with an author.
    # Text on one would be silently invisible, since every renderer reads
    # through to the boosted status.
    create constraint(:statuses, :statuses_boosts_have_no_content,
             check: "reblog_of_id IS NULL OR (text = '' AND spoiler_text = '')"
           )

    # The public timeline, as one index scan. Every predicate is a fact about
    # the row alone, so Postgres can serve the timeline from the index without
    # touching the table, walking id DESC and stopping at the page size.
    # `language` sits in the index because the timeline is filterable by it.
    create index(:statuses, ["id DESC", :language, :account_id],
             where: """
             deleted_at IS NULL
             AND visibility = 'public'
             AND reblog_of_id IS NULL
             AND (in_reply_to_id IS NULL OR in_reply_to_account_id = account_id)
             """,
             name: :statuses_public_timeline_index
           )

    create index(:statuses, ["id DESC", :language, :account_id],
             where: """
             deleted_at IS NULL
             AND local = TRUE
             AND visibility = 'public'
             AND reblog_of_id IS NULL
             AND (in_reply_to_id IS NULL OR in_reply_to_account_id = account_id)
             """,
             name: :statuses_local_timeline_index
           )

    # Snapshots, one per revision, so an edit history can be shown and so a
    # reader can see what they replied to rather than what it later became.
    create table(:status_edits) do
      add :status_id, references(:statuses, type: :bigint, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, type: :bigint, on_delete: :nilify_all)

      add :text, :text, null: false, default: ""
      add :spoiler_text, :text, null: false, default: ""
      add :sensitive, :boolean, null: false, default: false
      add :ordered_media_attachment_ids, {:array, :bigint}, null: false, default: []
      add :media_descriptions, {:array, :text}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create index(:status_edits, [:status_id, :id])

    create table(:mentions) do
      add :status_id, references(:statuses, type: :bigint, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      # A silent mention addresses somebody without notifying them. Replies
      # carry the whole thread's participants so the post reaches them, and
      # notifying everyone every time is how a long thread becomes a nuisance.
      add :silent, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mentions, [:status_id, :account_id])
    create index(:mentions, [:account_id, :status_id])

    create table(:tags) do
      # Stored casefolded so #Caturday and #caturday are one tag, with the
      # first-seen spelling kept for display.
      add :name, :string, null: false
      add :display_name, :string

      add :usable, :boolean, null: false, default: true
      add :trendable, :boolean, null: false, default: true
      add :listable, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tags, [:name])

    create table(:statuses_tags, primary_key: false) do
      add :status_id, references(:statuses, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :tag_id, references(:tags, on_delete: :delete_all), null: false, primary_key: true
    end

    # The hashtag timeline reads this way round: given a tag, the newest
    # statuses. The primary key above serves the other direction.
    create index(:statuses_tags, [:tag_id, :status_id])

    create table(:favourites) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false
      add :status_id, references(:statuses, type: :bigint, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:favourites, [:account_id, :status_id])
    create index(:favourites, [:status_id])

    create table(:bookmarks) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false
      add :status_id, references(:statuses, type: :bigint, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:bookmarks, [:account_id, :status_id])
  end
end
