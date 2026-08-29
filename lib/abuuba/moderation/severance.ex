defmodule Abuuba.Moderation.Severance do
  @moduledoc """
  One relationship a moderation decision destroyed.

  Suspending a domain deletes follows that people spent years building, and the
  accounts on the other side cannot be asked about it afterwards. Without a
  record the only thing somebody sees is a follower count that dropped
  overnight, and the honest answer to "who did I lose" would be that nobody
  here knows any more.

  Each row names the local account, so that everybody affected can be told and
  can read their own list. The decision itself is a
  `Abuuba.Moderation.SeveranceEvent`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Moderation.SeveranceEvent
  alias Abuuba.Snowflake

  @directions ~w(active passive)

  schema "severed_relationships" do
    field :direction, :string

    belongs_to :relationship_severance_event, SeveranceEvent
    belongs_to :local_account, Account, type: Snowflake
    belongs_to :remote_account, Account, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  The two ways an edge is lost: `active` is the local account following the
  remote one, `passive` the other way around.
  """
  @spec directions() :: [String.t()]
  def directions, do: @directions

  @doc false
  def changeset(severed, attrs) do
    severed
    |> cast(attrs, [
      :relationship_severance_event_id,
      :local_account_id,
      :remote_account_id,
      :direction
    ])
    |> validate_required([
      :relationship_severance_event_id,
      :local_account_id,
      :remote_account_id,
      :direction
    ])
    |> validate_inclusion(:direction, @directions)
  end
end
