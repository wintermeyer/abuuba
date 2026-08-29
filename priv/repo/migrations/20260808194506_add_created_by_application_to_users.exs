defmodule Abuuba.Repo.Migrations.AddCreatedByApplicationToUsers do
  @moduledoc """
  Which app signed somebody up, where an app did.

  Resending a confirmation mail is something only that app may ask for. An
  account made through one client and then confirmed through another is a
  confirmation nobody can attribute, and the check needs a column to make.

  Null for everybody who signed up in a browser, which is most people, and the
  check reads that as "no app may do this on their behalf".
  """

  use Ecto.Migration

  def change do
    alter table(:users) do
      add :created_by_application_id, references(:oauth_applications, on_delete: :nilify_all)
    end

    create index(:users, [:created_by_application_id])
  end
end
