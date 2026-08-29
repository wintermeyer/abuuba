defmodule Abuuba.OAuth.AuthorizationCode do
  @moduledoc """
  A short-lived code exchanged for a token.

  Stored hashed, used once, and tied to the exact redirect URI it was issued
  for. All three matter: a code is the one thing an attacker can hope to
  intercept, and each of the three closes a different way of using one.
  """

  use Ecto.Schema

  alias Abuuba.Accounts.User
  alias Abuuba.OAuth.Application

  schema "oauth_authorization_codes" do
    field :hashed_code, :string
    field :redirect_uri, :string
    field :scopes, :string
    field :code_challenge, :string
    field :code_challenge_method, :string
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    belongs_to :application, Application
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  Whether the code can still be exchanged.
  """
  def usable?(%__MODULE__{used_at: used_at, expires_at: expires_at}) do
    is_nil(used_at) and DateTime.before?(DateTime.utc_now(), expires_at)
  end
end
