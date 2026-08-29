defmodule Abuuba.Repo.Migrations.AddInstanceDetails do
  @moduledoc """
  What an admin needs to know about one peer, next to what this server already
  knows about reaching it.

  `instance_availability` holds a row only for a server that has been in
  trouble, which is the right shape for the failure bookkeeping and the wrong
  shape for a note: a moderator writing "these people were fine about the
  report we forwarded" is writing about a server that is working. So a row is
  created deliberately when there is something to say, and the failure path
  keeps costing nothing for healthy peers.

  The software and version are what the peer says about itself. Recorded rather
  than trusted: it is a self-report and the only thing it is good for is
  telling an admin what they are looking at.
  """

  use Ecto.Migration

  def change do
    alter table(:instance_availability) do
      # Why the last delivery failed, in the admin's own words rather than a
      # log line on a machine they may not have.
      add :last_error, :string
      add :last_error_at, :utc_datetime_usec

      # What the peer says it is running.
      add :software, :string
      add :version, :string

      # A moderator's note about this server. Never leaves this server.
      add :note, :text
    end
  end
end
