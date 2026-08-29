defmodule Abuuba.Statuses.Bookmark do
  @moduledoc """
  An account's private mark on a status. Unlike a favourite, nobody else sees
  it and it sends no notification.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Status

  schema "bookmarks" do
    belongs_to :account, Account, type: Snowflake
    belongs_to :status, Status, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  def changeset(bookmark, attrs) do
    bookmark
    |> cast(attrs, [:account_id, :status_id])
    |> validate_required([:account_id, :status_id])
    |> unique_constraint([:account_id, :status_id])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:status_id)
  end
end
