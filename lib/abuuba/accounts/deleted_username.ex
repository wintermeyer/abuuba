defmodule Abuuba.Accounts.DeletedUsername do
  @moduledoc """
  A name this server will not hand out again. See `Abuuba.Accounts.Deletion`.
  """

  use Ecto.Schema

  schema "deleted_usernames" do
    field :username, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}
end
