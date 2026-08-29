defmodule Abuuba.AsyncRefreshes.AsyncRefresh do
  @moduledoc """
  One piece of work a client is waiting on. See `Abuuba.AsyncRefreshes`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  @foreign_key_type Snowflake

  @statuses ~w(running finished)

  schema "async_refreshes" do
    field :key, :string
    field :status, :string, default: "running"
    field :result_count, :integer
    field :expires_at, :utc_datetime_usec

    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(refresh, attrs) do
    refresh
    |> cast(attrs, [:account_id, :key, :status, :result_count, :expires_at])
    |> validate_required([:account_id, :key, :status, :expires_at])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:account_id, :key], name: :async_refreshes_running_key_index)
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  Whether the work is still going.
  """
  @spec running?(t()) :: boolean()
  def running?(%__MODULE__{status: status}), do: status == "running"
end
