defmodule Abuuba.Relationships.Block do
  @moduledoc """
  One account refusing another. See `Abuuba.Relationships` for what a block
  tears down when it is created.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  schema "blocks" do
    field :uri, :string

    belongs_to :account, Account, type: Snowflake
    belongs_to :target_account, Account, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  def changeset(block, attrs) do
    block
    |> cast(attrs, [:account_id, :target_account_id, :uri])
    |> validate_required([:account_id, :target_account_id])
    |> validate_not_self()
    |> unique_constraint([:account_id, :target_account_id])
    |> check_constraint(:target_account_id, name: :blocks_no_self_reference)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:target_account_id)
  end

  defp validate_not_self(changeset) do
    if get_field(changeset, :account_id) == get_field(changeset, :target_account_id) do
      add_error(changeset, :target_account_id, "cannot be yourself")
    else
      changeset
    end
  end
end
