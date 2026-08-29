defmodule Abuuba.Repo.Migrations.CreateLoginActivities do
  @moduledoc """
  Every attempt to sign in to an account, successful or not.

  The failures are the point. A list of successful sign-ins tells somebody
  where they have been; a list that also holds the failures tells them
  somebody else has been trying, which is the thing worth knowing early and
  the thing nothing else on the server would ever surface.

  Kept short-lived by a sweep. This is a table of somebody's whereabouts and
  their addresses, so it exists to answer "was that me last Tuesday" and not to
  be an archive.
  """

  use Ecto.Migration

  def change do
    create table(:login_activities) do
      add :user_id, references(:users, type: :bigint, on_delete: :delete_all), null: false

      add :success, :boolean, null: false, default: false
      add :ip, :string
      add :user_agent, :string
      # `password`, `two_factor`, `webauthn` — which door was tried, because
      # a wrong password and a wrong second factor mean different things.
      add :method, :string
      add :failure_reason, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:login_activities, [:user_id, :id])
    create index(:login_activities, [:inserted_at])
  end
end
