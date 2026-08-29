defmodule Abuuba.Repo.Migrations.CreateSignupBlocks do
  use Ecto.Migration

  @moduledoc """
  What a server refuses at the door, and why each list is its own table.

  ## Email domains

  Blocked by name, and also by the mail servers the name points at. A
  disposable-address service runs a thousand domains off one set of MX records,
  and blocking them one at a time is a game nobody wins.

  `allow_with_approval` is the softer answer: not "no", but "a person looks at
  this one". A university that one spammer used is not a university that should
  be shut out.

  ## Canonical email addresses

  Stored as a hash of the normalised address, never the address itself. The
  list exists to recognise somebody who was suspended coming back, which needs
  a comparison and not the ability to read the addresses back out. Normalising
  first is what makes `a.b+spam@gmail.com` and `ab@gmail.com` the same person.

  ## IP addresses

  A range rather than a single address, and a severity rather than a flag: most
  of what an admin wants is "make these ones ask", not "shut the door". An
  expiry, because a residential address is somebody else's next month and a
  permanent block on one is a punishment aimed at a stranger.

  ## Usernames

  Exact or partial, matched against a normalised form so that a name spelled
  with a Cyrillic `а` is the same name as one spelled with a Latin `a`.
  """

  def change do
    create table(:email_domain_blocks) do
      add :domain, :string, null: false
      # Not "no", but "a person looks at this one".
      add :allow_with_approval, :boolean, null: false, default: false
      add :comment, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:email_domain_blocks, [:domain])

    create table(:canonical_email_blocks) do
      # A hash, never the address. The list has to recognise a returning
      # account, not be able to read the addresses back out.
      add :canonical_email_hash, :string, null: false
      add :reference_account_id, references(:accounts, type: :bigint, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:canonical_email_blocks, [:canonical_email_hash])

    create table(:ip_blocks) do
      # Text rather than `inet`, so that the same containment check runs in
      # Elixir for a single lookup and the table stays readable by hand.
      add :cidr, :string, null: false
      add :severity, :string, null: false, default: "sign_up_requires_approval"
      add :comment, :string
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ip_blocks, [:cidr])

    create constraint(:ip_blocks, :ip_blocks_severity_known,
             check: "severity in ('sign_up_requires_approval', 'sign_up_block', 'no_access')"
           )

    create table(:username_blocks) do
      # Stored normalised: confusable characters folded, case dropped.
      add :username, :string, null: false
      add :exact, :boolean, null: false, default: true
      add :comment, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:username_blocks, [:username, :exact])

    alter table(:users) do
      # Where somebody signed up from, for an IP block written afterwards to
      # mean something, and for an admin to see a wave of registrations for
      # what it is.
      add :sign_up_ip, :string
    end
  end
end
