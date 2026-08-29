defmodule Abuuba.Roles.Role do
  @moduledoc """
  A named set of permissions, and where it sits in the hierarchy.

  ## The permissions are a bitmask

  Twenty flags checked on nearly every admin request. As rows that would be a
  join and a set-membership test per check; as a bigint it is an AND against a
  number already loaded with the user.

  The bit positions are the reference implementation's, which is a protocol
  fact rather than a preference: its admin API hands these numbers to clients,
  and a client that knows one server should not have to translate for another.

  ## Position is the whole hierarchy

  Higher acts on lower, and nobody acts on a peer. That one rule stops two
  moderators unmaking each other and stops anybody promoting themselves, and it
  is one integer rather than a graph.
  """

  use Ecto.Schema

  import Ecto.Changeset

  # The role everybody has sits below every real one. Nothing may be created at
  # or under it, or it would be a role nobody could ever act on.
  @everyone_position -1

  schema "user_roles" do
    field :name, :string, default: ""
    field :color, :string, default: ""
    field :highlighted, :boolean, default: false
    field :position, :integer, default: 0
    field :permissions, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :color, :highlighted, :position, :permissions])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 40)
    |> validate_number(:position, greater_than: @everyone_position)
    |> validate_number(:permissions, greater_than_or_equal_to: 0)
    |> unique_constraint(:name)
  end

  @doc """
  Where the role everybody has sits.
  """
  @spec everyone_position() :: integer()
  def everyone_position, do: @everyone_position
end
