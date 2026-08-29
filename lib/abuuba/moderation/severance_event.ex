defmodule Abuuba.Moderation.SeveranceEvent do
  @moduledoc """
  One decision that destroyed relationships.

  The edges it destroyed are `Abuuba.Moderation.Severance` rows pointing here.
  `target_name` is kept as text rather than as a reference, because the block
  it names may be lifted later and the record still has to be able to say what
  happened.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @types ~w(domain_block user_domain_block account_suspension)

  schema "relationship_severance_events" do
    field :type, :string
    field :target_name, :string
    field :purged, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  The kinds of decision that sever relationships.
  """
  @spec types() :: [String.t()]
  def types, do: @types

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:type, :target_name, :purged])
    |> validate_required([:type, :target_name])
    |> validate_inclusion(:type, @types)
  end
end
