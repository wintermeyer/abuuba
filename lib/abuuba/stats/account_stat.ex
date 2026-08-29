defmodule Abuuba.Stats.AccountStat do
  @moduledoc """
  An account's counter cache. See `Abuuba.Stats` for why it is a table of its own
  and why nothing ever reads-modifies-writes it.
  """

  use Ecto.Schema

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  @primary_key false

  schema "account_stats" do
    belongs_to :account, Account, type: Snowflake, primary_key: true

    field :statuses_count, :integer, default: 0
    field :following_count, :integer, default: 0
    field :followers_count, :integer, default: 0
    field :last_status_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}
end
