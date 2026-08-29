defmodule Abuuba.Repo.Migrations.AddInstanceAvailability do
  @moduledoc """
  Which servers have stopped answering, and for how long.

  Counted in distinct days rather than in failures. A server that is down for
  an hour produces thousands of failures and is not dead; a server that has
  failed on seven separate days is. Counting days is what tells a bad afternoon
  apart from an abandoned instance, and it is the difference between backing
  off sensibly and giving up on somebody's server because their disk filled up
  over lunch.
  """
  use Ecto.Migration

  def change do
    create table(:instance_availability, primary_key: false) do
      add :domain, :string, primary_key: true

      # The dates on which every retry for this domain was exhausted. An array
      # rather than a counter, so that ten failures on one day count once.
      add :failure_days, {:array, :date}, null: false, default: []
      add :unavailable_since, :utc_datetime_usec
      add :last_success_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:instance_availability, [:unavailable_since],
             where: "unavailable_since IS NOT NULL"
           )
  end
end
