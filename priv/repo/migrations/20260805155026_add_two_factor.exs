defmodule Abuuba.Repo.Migrations.AddTwoFactor do
  @moduledoc """
  A second factor: an authenticator app, a security key, or a recovery code.

  The TOTP secret is encrypted at rest by `Abuuba.Vault`. It is a shared secret,
  which means anybody who can read the column can generate valid codes forever
  and the account holder has no way to notice. That makes it closer to a
  password than to a password hash, and it has to be treated accordingly.

  Recovery codes are hashed rather than encrypted. Nothing ever needs to read
  one back, only to check that a code somebody typed matches, and a hash cannot
  be turned back into the printed sheet.

  `otp_required_at` is separate from having a secret. Enrolment sets up a
  secret and shows the QR code, and only a correct code from the app switches
  the requirement on; otherwise somebody who mis-scanned the QR would be locked
  out of their own account by their own setup.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :otp_secret, :binary
      add :otp_required_at, :utc_datetime_usec

      # The last window accepted, so the same code cannot be replayed inside
      # the 30 seconds it stays valid. Somebody reading a code over a shoulder,
      # or off a phished form, otherwise gets to use it too.
      add :otp_last_used_at, :utc_datetime_usec
    end

    create table(:recovery_codes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :hashed_code, :string, null: false
      add :used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:recovery_codes, [:user_id])

    create table(:webauthn_credentials) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :credential_id, :binary, null: false
      add :public_key, :binary, null: false
      add :nickname, :string, null: false, default: ""

      # A counter that goes backwards means the same key exists twice, which
      # means one of them is a clone. Storing it is the only way to notice.
      add :sign_count, :bigint, null: false, default: 0
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webauthn_credentials, [:credential_id])
    create index(:webauthn_credentials, [:user_id])
  end
end
