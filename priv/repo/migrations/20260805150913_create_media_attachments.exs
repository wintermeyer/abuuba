defmodule Abuuba.Repo.Migrations.CreateMediaAttachments do
  @moduledoc """
  Uploaded files, deliberately not owned by a status.

  Both `status_id` and `account_id` are nullable, and that is the point of the
  table's shape. Composing a post starts with the upload: a person picks a
  photo, waits for it to process, and only then writes the text and presses
  post. The attachment therefore exists before the status does, and has to be
  addressable in the meantime.

  Deleting a status nils the pointer rather than removing the row, so the file
  on disk still has a record pointing at it for the sweeper to clean up. An
  attachment that has been unattached for long enough is exactly what that
  sweeper looks for.

  Ordering lives on `statuses.ordered_media_attachment_ids`, not here. The
  author's chosen order is a property of the post, and a position column on
  this side would have to be kept in step with it.
  """
  use Ecto.Migration

  import Abuuba.Snowflake.Migration

  def change do
    create table(:media_attachments, primary_key: false) do
      add :id, :bigint, primary_key: true

      add :status_id, references(:statuses, type: :bigint, on_delete: :nilify_all)
      add :account_id, references(:accounts, type: :bigint, on_delete: :nilify_all)

      add :type, :string, null: false, default: "unknown"
      add :processing, :string, null: false, default: "queued"

      add :file_file_name, :text
      add :file_content_type, :string
      add :file_file_size, :bigint

      add :thumbnail_file_name, :text
      add :thumbnail_content_type, :string
      add :thumbnail_file_size, :bigint

      # Dimensions, focus point, duration, frame rate, average colour. Free
      # form because it differs per type, and the client API passes it through.
      add :meta, :map, null: false, default: fragment("'{}'::jsonb")

      # A tiny blurred stand-in, rendered while the real image loads and shown
      # in place of one marked sensitive.
      add :blurhash, :string

      add :description, :text

      # Empty string, never null, for a file we hold ourselves. That is what
      # Mastodon stores and what its API returns, and the importer has to be
      # able to move rows across without rewriting what a column means.
      add :remote_url, :text, null: false, default: ""

      timestamps(type: :utc_datetime_usec)
    end

    use_timestamp_ids(:media_attachments)

    create index(:media_attachments, [:status_id])
    create index(:media_attachments, [:account_id, :id])

    create constraint(:media_attachments, :media_attachments_type_known,
             check: "type IN ('image', 'gifv', 'video', 'audio', 'unknown')"
           )

    create constraint(:media_attachments, :media_attachments_processing_known,
             check: "processing IN ('queued', 'in_progress', 'complete', 'failed')"
           )

    # What the storage sweeper scans: uploads that were never posted, and those
    # orphaned when their status was deleted. Partial, because attached rows
    # are the overwhelming majority and can never qualify.
    create index(:media_attachments, [:id],
             where: "status_id IS NULL",
             name: :media_attachments_unattached_index
           )
  end
end
