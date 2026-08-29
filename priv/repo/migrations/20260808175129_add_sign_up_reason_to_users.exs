defmodule Abuuba.Repo.Migrations.AddSignUpReasonToUsers do
  @moduledoc """
  Keeps what somebody wrote when they asked to join.

  On a server whose registrations are moderated, the sign-up form requires a
  few words about why somebody wants an account, and until now those words were
  validated and then dropped. The moderator deciding on the account never saw
  them, which makes the question a hurdle for the applicant and nothing at all
  for the person it was asked on behalf of.

  A column on `users` rather than a table of its own: it is one piece of text
  per user, written once at sign-up and read on the approval screen, and a
  second table would be a join for every pending list to hold one string.
  """

  use Ecto.Migration

  def change do
    alter table(:users) do
      add :sign_up_reason, :text
    end
  end
end
