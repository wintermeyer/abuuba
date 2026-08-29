defmodule Abuuba.Statuses.Mention do
  @moduledoc """
  An account addressed by a status.

  A silent mention addresses somebody without notifying them. A reply carries
  every participant of the thread so that the post actually reaches them, and
  notifying all of them on every reply is how a long thread turns into a
  nuisance. The mention still governs delivery; only the notification is
  suppressed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Status

  schema "mentions" do
    field :silent, :boolean, default: false

    belongs_to :status, Status, type: Snowflake
    belongs_to :account, Account, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  def changeset(mention, attrs) do
    mention
    |> cast(attrs, [:status_id, :account_id, :silent])
    |> validate_required([:status_id, :account_id])
    |> unique_constraint([:status_id, :account_id])
    |> foreign_key_constraint(:status_id)
    |> foreign_key_constraint(:account_id)
  end
end
