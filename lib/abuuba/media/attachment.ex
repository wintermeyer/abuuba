defmodule Abuuba.Media.Attachment do
  @moduledoc """
  An uploaded file.

  An attachment outlives both of its pointers. It is created before the status
  that will carry it exists, and it survives that status being deleted, so that
  the file on disk still has a record to be cleaned up by. Neither `status_id`
  nor `account_id` can therefore be relied on to be present.

  `remote_url` is an empty string, never null, for a file this server holds.
  That is a Mastodon quirk rather than a choice: its API returns `""` there and
  clients test for it, and the importer moves rows across without having to
  rewrite what the column means.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Media.Attachment
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Status

  @types [
    image: "image",
    gifv: "gifv",
    video: "video",
    audio: "audio",
    unknown: "unknown"
  ]

  @processing_states [
    queued: "queued",
    in_progress: "in_progress",
    complete: "complete",
    failed: "failed"
  ]

  # Generous, because a good description of a complex image or a chart is long,
  # and cutting one off is worse than storing it. Clients impose their own,
  # tighter limit when composing.
  @description_max 10_000

  @primary_key {:id, Snowflake, autogenerate: false, read_after_writes: true}
  @foreign_key_type Snowflake

  schema "media_attachments" do
    field :type, Ecto.Enum, values: @types, default: :unknown
    field :processing, Ecto.Enum, values: @processing_states, default: :queued

    field :file_file_name, :string
    field :file_content_type, :string
    field :file_file_size, :integer

    field :thumbnail_file_name, :string
    field :thumbnail_content_type, :string
    field :thumbnail_file_size, :integer

    field :meta, :map, default: %{}
    field :blurhash, :string
    field :description, :string
    field :remote_url, :string, default: ""

    belongs_to :status, Status
    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @castable ~w(status_id account_id type processing file_file_name
               file_content_type file_file_size thumbnail_file_name
               thumbnail_content_type thumbnail_file_size meta blurhash
               description remote_url)a

  @doc """
  The longest description a picture may carry, for anybody cutting one to fit.
  """
  @spec max_description() :: pos_integer()
  def max_description, do: @description_max

  @doc """
  Changeset for an attachment.
  """
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, @castable)
    |> validate_length(:description, max: @description_max)
    |> validate_number(:file_file_size, greater_than_or_equal_to: 0)
    |> validate_number(:thumbnail_file_size, greater_than_or_equal_to: 0)
    |> normalise_remote_url()
    |> normalise_description()
    |> check_constraint(:type, name: :media_attachments_type_known)
    |> check_constraint(:processing, name: :media_attachments_processing_known)
    |> foreign_key_constraint(:status_id)
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  Changeset for the alt text, which is the one field its author edits after the
  upload has finished.
  """
  def description_changeset(attachment, attrs) do
    attachment
    # `:meta` is castable here because it is the focal point, which is the
    # owner's to set. The caller builds that map from the request rather than
    # handing this one the request's own: a client that could write `meta`
    # wholesale could rewrite the recorded size and type of its own upload.
    |> cast(attrs, [:description, :meta])
    |> validate_length(:description, max: @description_max)
    |> normalise_description()
  end

  # Null here would mean "local" to Postgres and "remote, address unknown" to
  # every reader of the column. Collapse it to the sentinel the rest of the
  # fediverse uses.
  defp normalise_remote_url(changeset) do
    case fetch_change(changeset, :remote_url) do
      {:ok, nil} -> put_change(changeset, :remote_url, "")
      _ -> changeset
    end
  end

  # An alt text of spaces is worse than none: a screen reader announces the
  # image as described and then says nothing.
  defp normalise_description(changeset) do
    update_change(changeset, :description, fn
      nil -> nil
      description -> if String.trim(description) == "", do: nil, else: description
    end)
  end

  @doc """
  Whether this server holds the file itself.
  """
  def local?(%Attachment{remote_url: ""}), do: true
  def local?(%Attachment{remote_url: nil}), do: true
  def local?(%Attachment{}), do: false

  @doc """
  Whether the file is ready to be shown.
  """
  def ready?(%Attachment{processing: :complete}), do: true
  def ready?(%Attachment{}), do: false

  @doc """
  Whether the attachment is waiting to be posted, or orphaned by a deletion.
  """
  def unattached?(%Attachment{status_id: nil}), do: true
  def unattached?(%Attachment{}), do: false

  @doc """
  The types an attachment may have.
  """
  def types, do: Keyword.keys(@types)

  @doc """
  The states processing moves through.
  """
  def processing_states, do: Keyword.keys(@processing_states)

  @doc """
  The longest alt text that will be stored.
  """
  def description_max, do: @description_max
end
