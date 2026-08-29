defmodule Abuuba.Statuses.Favourite do
  @moduledoc """
  An account marking a status as a favourite. At most one per pair.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Status

  schema "favourites" do
    belongs_to :account, Account, type: Snowflake
    belongs_to :status, Status, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  def changeset(favourite, attrs) do
    favourite
    |> cast(attrs, [:account_id, :status_id])
    |> validate_required([:account_id, :status_id])
    |> unique_constraint([:account_id, :status_id])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:status_id)
  end
end
