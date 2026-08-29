defmodule Abuuba.Collections.Item do
  @moduledoc """
  One account on somebody's list.

  `state` carries what the listed account has said about being there.
  `accepted` is the ordinary case; `revoked` is somebody who took themselves
  off and is kept as a row rather than deleted, so they cannot simply be added
  again. `pending` and `rejected` exist for accounts on other servers, whose
  own server has to answer, and nothing produces them yet.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Collections.Collection
  alias Abuuba.Snowflake

  @states ~w(pending accepted rejected revoked)

  @foreign_key_type Snowflake

  schema "collection_items" do
    field :position, :integer, default: 1
    field :state, :string, default: "accepted"

    belongs_to :collection, Collection, type: :id
    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  The states an item may be in.
  """
  @spec states() :: [String.t()]
  def states, do: @states

  @doc """
  Whether an item is one a reader should be shown.
  """
  @spec visible?(t()) :: boolean()
  def visible?(%__MODULE__{state: state}), do: state in ["pending", "accepted"]

  @doc false
  def changeset(item, attrs) do
    item
    |> cast(attrs, [:collection_id, :account_id, :position, :state])
    |> validate_required([:collection_id, :account_id])
    |> validate_inclusion(:state, @states)
    |> validate_number(:position, greater_than: 0)
    |> unique_constraint([:collection_id, :account_id],
      name: :collection_items_collection_id_account_id_index
    )
    |> foreign_key_constraint(:collection_id)
    |> foreign_key_constraint(:account_id)
  end
end
