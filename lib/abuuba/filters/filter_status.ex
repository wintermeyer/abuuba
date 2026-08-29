defmodule Abuuba.Filters.FilterStatus do
  @moduledoc """
  One post caught by a filter by hand, rather than by any word in it.

  For the post that gets past a rule somebody wrote — the one that talks about
  the thing without ever naming it. A keyword cannot express "that one", so
  this is how a person says it.

  It hangs off the filter rather than off the account so that lifting the rule
  lifts everything it was doing, including the posts named one at a time.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Filters.Filter
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Status

  @primary_key {:id, Snowflake, autogenerate: false, read_after_writes: true}
  @foreign_key_type Snowflake

  schema "filter_statuses" do
    belongs_to :filter, Filter
    belongs_to :status, Status

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(filter_status, attrs) do
    filter_status
    |> cast(attrs, [:filter_id, :status_id])
    |> validate_required([:filter_id, :status_id])
    |> unique_constraint([:filter_id, :status_id],
      name: :filter_statuses_filter_id_status_id_index
    )
    |> foreign_key_constraint(:filter_id)
    |> foreign_key_constraint(:status_id)
  end
end
