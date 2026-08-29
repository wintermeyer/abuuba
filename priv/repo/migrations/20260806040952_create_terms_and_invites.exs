defmodule Abuuba.Repo.Migrations.CreateTermsAndInvites do
  use Ecto.Migration

  @moduledoc """
  The four ways a server talks to the people on it before anything goes wrong.

  ## Terms are versioned, never edited

  Each version is its own row with the date it takes effect. Editing the terms
  in place would leave every account that agreed to them pointing at text they
  never read, and "what did I agree to in March" is exactly the question terms
  exist to answer.

  ## Rules carry translations rather than being duplicated

  A translations map on the rule itself, so the German text is the same rule as
  the English one. Two rows would be two rules that drift apart, and a
  moderation decision would then be recorded against whichever language the
  moderator happened to be reading.

  ## An invite is a code with a budget

  Uses and an expiry rather than a single-shot token, because the common case
  is one link handed to a group. The count is on the row rather than derived
  from who signed up, so an invite still says how much of it is left after the
  accounts it created have been deleted.

  ## Announcements can be written before they are meant

  `scheduled_at` is what turns "the server is down on Sunday" into something an
  admin writes on Thursday and forgets about, rather than something they have
  to be awake to publish.
  """

  def change do
    create table(:terms_of_service) do
      add :text, :text, null: false
      # A date rather than a timestamp: terms take effect on a day, and a
      # timezone-dependent moment is a promise nobody can read off the page.
      add :effective_date, :date, null: false
      add :published_at, :utc_datetime_usec
      add :notified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:terms_of_service, [:effective_date])

    create table(:invites) do
      add :code, :string, null: false
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false
      add :comment, :string
      add :expires_at, :utc_datetime_usec
      # Null is "as many as you like". Zero would read as none, which is the
      # opposite of what an admin leaving the field empty meant.
      add :max_uses, :integer
      add :uses, :integer, null: false, default: 0
      # Whether somebody arriving on this invite follows whoever wrote it. The
      # point of an invite is usually that the two already know each other.
      add :autofollow, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:invites, [:code])
    create index(:invites, [:account_id, :id])

    alter table(:users) do
      # Which invite let somebody in, kept so an admin can see where a wave of
      # sign-ups came from. Nilified rather than cascading: deleting an invite
      # must not delete the people who used it.
      add :invite_id, references(:invites, on_delete: :nilify_all)
    end

    alter table(:server_rules) do
      # Locale to text, for the languages somebody has bothered to translate.
      # A rule with no translation for a reader's language falls back to the
      # text it was written in rather than disappearing.
      add :translations, :map, null: false, default: %{}
    end

    alter table(:announcements) do
      add :scheduled_at, :utc_datetime_usec
    end

    create index(:announcements, [:scheduled_at])
  end
end
