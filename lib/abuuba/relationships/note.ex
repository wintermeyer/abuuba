defmodule Abuuba.Relationships.Note do
  @moduledoc """
  A private note one account keeps about another. Never shown to its subject.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  schema "account_notes" do
    field :comment, :string, default: ""

    belongs_to :account, Account, type: Snowflake
    belongs_to :target_account, Account, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:account_id, :target_account_id, :comment])
    |> validate_required([:account_id, :target_account_id])
    |> validate_length(:comment, max: 2_000)
    |> unique_constraint([:account_id, :target_account_id])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:target_account_id)
  end
end
