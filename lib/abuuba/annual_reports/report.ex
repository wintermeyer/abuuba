defmodule Abuuba.AnnualReports.Report do
  @moduledoc """
  One person's year, as generated.

  `data` holds the whole thing. See `Abuuba.AnnualReports` for what is in it and
  why none of it is private.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  @foreign_key_type Snowflake

  schema "annual_reports" do
    field :year, :integer
    field :data, :map, default: %{}
    field :schema_version, :integer, default: 1
    field :viewed_at, :utc_datetime_usec

    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(report, attrs) do
    report
    |> cast(attrs, [:account_id, :year, :data, :schema_version, :viewed_at])
    |> validate_required([:account_id, :year])
    |> unique_constraint([:account_id, :year],
      name: :annual_reports_account_id_year_index
    )
    |> foreign_key_constraint(:account_id)
  end
end
