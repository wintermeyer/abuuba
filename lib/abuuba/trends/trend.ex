defmodule Abuuba.Trends.Trend do
  @moduledoc """
  One row of a ranking: what it is, how it scored, and where it came in.

  Rewritten wholesale on every recompute rather than updated in place. See
  `Abuuba.Trends`.
  """

  use Ecto.Schema

  schema "trends" do
    field :kind, :string
    field :subject, :string
    field :language, :string
    field :score, :float, default: 0.0
    field :rank, :integer, default: 0
    field :uses, :integer, default: 0
    field :accounts, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}
end
