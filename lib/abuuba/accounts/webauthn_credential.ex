defmodule Abuuba.Accounts.WebauthnCredential do
  @moduledoc """
  A registered security key or passkey.

  The `sign_count` is the reason this is a table rather than a flag. A real
  authenticator only ever counts up, so a count that fails to advance means the
  same key material exists in two places, which is to say one of them is a
  clone. See `Abuuba.Accounts.TwoFactor.record_webauthn_use/2`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.User

  schema "webauthn_credentials" do
    field :credential_id, :binary
    field :public_key, :binary
    field :nickname, :string, default: ""
    field :sign_count, :integer, default: 0
    field :last_used_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:user_id, :credential_id, :public_key, :nickname, :sign_count])
    |> validate_required([:user_id, :credential_id, :public_key])
    |> validate_length(:nickname, max: 60)
    |> unique_constraint(:credential_id)
    |> foreign_key_constraint(:user_id)
  end
end
