defmodule Abuuba.Statuses.Pin do
  @moduledoc """
  A post an account has put at the top of its own profile.

  Only an account's own posts, and only public ones. A pin is a profile
  decoration that everybody who visits the profile sees, so pinning a
  followers-only post would publish it to people it was never addressed to.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Status

  schema "status_pins" do
    belongs_to :account, Account, type: Snowflake
    belongs_to :status, Status, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(pin, attrs) do
    pin
    |> cast(attrs, [:account_id, :status_id])
    |> validate_required([:account_id, :status_id])
    |> unique_constraint([:account_id, :status_id])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:status_id)
  end
end
