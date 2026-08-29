defmodule Abuuba.Accounts.LoginActivity do
  @moduledoc """
  One attempt to sign in. See `Abuuba.Accounts.LoginActivities`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.User
  alias Abuuba.Snowflake

  @foreign_key_type Snowflake

  schema "login_activities" do
    field :success, :boolean, default: false
    field :ip, :string
    field :user_agent, :string
    field :method, :string
    field :failure_reason, :string

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(activity, attrs) do
    activity
    |> cast(attrs, [:user_id, :success, :ip, :user_agent, :method, :failure_reason])
    |> validate_required([:user_id])
    # A user agent is whatever a client sends and some send a paragraph. Cut
    # rather than refused: the row is worth having even when the string is silly.
    |> update_change(:user_agent, &String.slice(to_string(&1), 0, 300))
    |> foreign_key_constraint(:user_id)
  end
end
