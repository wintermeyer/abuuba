defmodule Abuuba.Relationships.DomainBlock do
  @moduledoc """
  One account refusing a whole server.

  Distinct from the instance-wide domain blocks a moderator sets: this one is
  personal, affects only its owner's timelines, and other people on the same
  server are unaffected by it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  schema "account_domain_blocks" do
    field :domain, :string

    belongs_to :account, Account, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  def changeset(block, attrs) do
    block
    |> cast(attrs, [:account_id, :domain])
    |> validate_required([:account_id, :domain])
    # Normalised the same way as accounts.domain, or a block written with
    # different capitalisation would silently match nothing.
    |> update_change(:domain, &(&1 |> String.trim() |> String.downcase()))
    |> validate_length(:domain, min: 1)
    |> unique_constraint([:account_id, :domain])
    |> foreign_key_constraint(:account_id)
  end
end
