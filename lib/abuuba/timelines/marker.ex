defmodule Abuuba.Timelines.Marker do
  @moduledoc """
  Where somebody had read up to on one timeline.

  The version is what makes two clients safe. A phone and a laptop both hold a
  marker, both move it, and last-write-wins would silently drag somebody's
  place backwards to whatever the slower device thought was current. Instead
  the second write is refused and the client re-reads.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  @timelines ~w(home notifications)

  @primary_key false

  schema "markers" do
    field :timeline, :string, primary_key: true
    field :last_read_id, :integer
    field :version, :integer, default: 1

    belongs_to :account, Account, type: Snowflake, primary_key: true

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(marker, attrs) do
    marker
    |> cast(attrs, [:account_id, :timeline, :last_read_id, :version])
    |> validate_required([:account_id, :timeline, :last_read_id])
    |> validate_inclusion(:timeline, @timelines)
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  The timelines a marker may be kept for.
  """
  @spec timelines() :: [String.t()]
  def timelines, do: @timelines
end
