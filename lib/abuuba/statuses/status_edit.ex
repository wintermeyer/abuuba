defmodule Abuuba.Statuses.StatusEdit do
  @moduledoc """
  A snapshot of a status as it read at one point in time.

  Editing a post that other people have already replied to changes what their
  replies appear to be answering, so every revision is kept. The client API
  serves these as the edit history, and a reader can see the version that was
  actually in front of whoever replied.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Status

  schema "status_edits" do
    field :text, :string, default: ""
    field :spoiler_text, :string, default: ""
    field :sensitive, :boolean, default: false
    field :ordered_media_attachment_ids, {:array, :integer}, default: []
    field :media_descriptions, {:array, :string}, default: []

    belongs_to :status, Status, type: Snowflake
    belongs_to :account, Account, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  def changeset(edit, attrs) do
    edit
    |> cast(attrs, [
      :status_id,
      :account_id,
      :text,
      :spoiler_text,
      :sensitive,
      :ordered_media_attachment_ids,
      :media_descriptions
    ])
    |> validate_required([:status_id])
    |> foreign_key_constraint(:status_id)
  end

  @doc """
  Builds a snapshot of a status as it stands right now.
  """
  def from_status(%Status{} = status) do
    %__MODULE__{
      status_id: status.id,
      account_id: status.account_id,
      text: status.text,
      spoiler_text: status.spoiler_text,
      sensitive: status.sensitive,
      ordered_media_attachment_ids: status.ordered_media_attachment_ids
    }
  end
end
