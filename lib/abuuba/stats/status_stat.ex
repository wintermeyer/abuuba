defmodule Abuuba.Stats.StatusStat do
  @moduledoc """
  A status's counter cache. See `Abuuba.Stats`.
  """

  use Ecto.Schema

  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Status

  @primary_key false

  schema "status_stats" do
    belongs_to :status, Status, type: Snowflake, primary_key: true

    field :replies_count, :integer, default: 0
    field :reblogs_count, :integer, default: 0
    field :favourites_count, :integer, default: 0
    field :quotes_count, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}
end
