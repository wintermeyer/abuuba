defmodule Abuuba.Repo.Migrations.AddLastErrorToRelays do
  @moduledoc """
  Why a relay is not working, in the admin's own words rather than a log line.

  A relay that is silently failing looks exactly like a relay nobody has posted
  to yet, and the admin's next move is different in each case. The last error is
  the one thing that tells them apart, and it belongs next to the state rather
  than in a file on a machine they may not have.
  """

  use Ecto.Migration

  def change do
    alter table(:relays) do
      add :last_error, :string
      add :last_error_at, :utc_datetime_usec
      add :last_delivery_at, :utc_datetime_usec
    end
  end
end
