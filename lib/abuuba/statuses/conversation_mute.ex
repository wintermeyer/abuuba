defmodule Abuuba.Statuses.ConversationMute do
  @moduledoc """
  A thread somebody has stopped wanting to hear about.

  Keyed on the conversation rather than on the status, because the point of
  muting a thread is the replies nobody has written yet. Keyed on a status one
  could only ever mute the past.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Conversation

  schema "conversation_mutes" do
    belongs_to :account, Account, type: Snowflake
    belongs_to :conversation, Conversation, type: :id

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(mute, attrs) do
    mute
    |> cast(attrs, [:account_id, :conversation_id])
    |> validate_required([:account_id, :conversation_id])
    |> unique_constraint([:account_id, :conversation_id])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:conversation_id)
  end
end
