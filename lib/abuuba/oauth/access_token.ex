defmodule Abuuba.OAuth.AccessToken do
  @moduledoc """
  A token an application uses to act, either for a person or for itself.

  Stored hashed and without an expiry. See the migration for why there is no
  expiry and no refresh token.
  """

  use Ecto.Schema

  alias Abuuba.Accounts.User
  alias Abuuba.OAuth.Application

  schema "oauth_access_tokens" do
    field :hashed_token, :string
    field :scopes, :string
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec

    belongs_to :application, Application
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  Whether the token may still be used.
  """
  def live?(%__MODULE__{revoked_at: nil}), do: true
  def live?(%__MODULE__{}), do: false

  @doc """
  Whether the token acts for the application itself rather than for a person.
  """
  def app_only?(%__MODULE__{user_id: nil}), do: true
  def app_only?(%__MODULE__{}), do: false
end
