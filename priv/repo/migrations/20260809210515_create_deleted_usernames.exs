defmodule Abuuba.Repo.Migrations.CreateDeletedUsernames do
  @moduledoc """
  Names that belonged to somebody, and can never belong to anybody else.

  A closed account's row is deleted outright, so that every foreign key
  cascading off it fires and the account really goes. That frees the username,
  and a freed username is the one part of a deletion that lands on a third
  party: every old mention, link, archived page and screenshot of `@alice`
  would then point at whoever registered it next. Nobody has to intend that for
  it to be impersonation.

  So the name is copied here first. One column, no account behind it, nothing
  about the person who had it — just a word this server will not hand out
  again.
  """

  use Ecto.Migration

  def change do
    create table(:deleted_usernames) do
      add :username, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:deleted_usernames, ["lower(username)"],
             name: :deleted_usernames_lower_username_index
           )
  end
end
