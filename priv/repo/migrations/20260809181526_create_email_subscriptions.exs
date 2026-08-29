defmodule Abuuba.Repo.Migrations.CreateEmailSubscriptions do
  @moduledoc """
  Addresses that asked one account to write to them.

  Not an account and not a follow: somebody who reads a newsletter and has no
  interest in joining a social network. The row holds nothing but the address,
  the language to write in, and whether the address itself has agreed.

  Nothing is sent before `confirmed_at` is set. Anybody can type anybody's
  address into a form, so an unconfirmed row is a claim rather than a
  subscription, and treating it as one is how a server becomes a way to mail
  strangers.
  """

  use Ecto.Migration

  def change do
    create table(:email_subscriptions) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false
      add :email, :string, null: false
      add :locale, :string, null: false, default: "en"

      # Serves both the confirmation link and the unsubscribe link, and is kept
      # after confirming for exactly that reason: an unsubscribe that needs the
      # reader to remember a password is an unsubscribe that does not happen.
      add :token, :string, null: false

      add :confirmed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:email_subscriptions, [:token])
    create unique_index(:email_subscriptions, [:account_id, :email])

    # What the nightly purge walks. Partial, because the rows it is looking for
    # are the minority and the ones it is not are the whole point of the table.
    create index(:email_subscriptions, [:inserted_at], where: "confirmed_at is null")
  end
end
