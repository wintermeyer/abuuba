defmodule Abuuba.Statuses.PollVote do
  @moduledoc """
  One person's answer to one option.

  A poll that allows several answers gets several rows, which is why the row is
  per choice rather than per person. The unique index is on all three columns,
  so answering twice is refused while answering differently is not.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Poll

  schema "poll_votes" do
    field :choice, :integer
    field :uri, :string

    belongs_to :poll, Poll, type: Snowflake
    belongs_to :account, Account, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:poll_id, :account_id, :choice, :uri])
    |> validate_required([:poll_id, :account_id, :choice])
    |> validate_number(:choice, greater_than_or_equal_to: 0)
    |> unique_constraint([:poll_id, :account_id, :choice])
    |> foreign_key_constraint(:poll_id)
    |> foreign_key_constraint(:account_id)
  end
end
