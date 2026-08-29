defmodule Abuuba.Repo.Migrations.CreateWeeklyLogins do
  @moduledoc """
  One row per week: how many people signed in, and nothing about who.

  `login_activities` is swept after 30 days because it is a record of where
  people were. The activity endpoint answers twelve weeks, so the count has to
  outlive the detail: each completed week's distinct-user number is frozen
  here before the sweep takes the rows it was computed from.
  """

  use Ecto.Migration

  def change do
    create table(:weekly_logins, primary_key: false) do
      add :week_start, :date, primary_key: true
      add :count, :integer, null: false, default: 0
    end
  end
end
