defmodule Abuuba.Notifications.Request do
  @moduledoc """
  One sender whose notifications were filtered out of the main list.

  A row per person rather than per event, because accepting one is a decision
  about the person: "yes, I do want to hear from them", not "yes to this one
  mention". The count and the last post are what a client shows so somebody can
  make that decision without opening it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Status

  schema "notification_requests" do
    field :notifications_count, :integer, default: 0
    field :dismissed_at, :utc_datetime_usec

    belongs_to :account, Account, type: Snowflake
    belongs_to :from_account, Account, type: Snowflake
    belongs_to :last_status, Status, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :account_id,
      :from_account_id,
      :notifications_count,
      :last_status_id,
      :dismissed_at
    ])
    |> validate_required([:account_id, :from_account_id])
    |> unique_constraint([:account_id, :from_account_id])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:from_account_id)
  end
end
