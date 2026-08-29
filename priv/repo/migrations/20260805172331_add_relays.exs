defmodule Abuuba.Repo.Migrations.AddRelays do
  @moduledoc """
  Relays a small server subscribes to so that it sees more than its own corner.

  A relay is a server that forwards every public post it is sent on to everybody
  subscribed to it. For a new instance with three accounts and no follows that
  is the difference between an empty federated timeline and a populated one, so
  it is usually the first thing an admin turns on.

  Kept as a table of inbox URLs rather than as ordinary accounts, because a
  relay is not somebody anybody follows. Nothing in the account model would
  have a sensible answer for it.
  """
  use Ecto.Migration

  def change do
    create table(:relays) do
      add :inbox_url, :string, null: false

      # The subscription is a Follow the relay answers at its leisure, so the
      # state has to survive a restart while we are waiting.
      add :state, :string, null: false, default: "idle"

      # The id of the Follow we sent. A relay's Accept names it, and that name
      # is the only thing tying the answer back to the request.
      add :follow_activity_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:relays, [:inbox_url])
    create unique_index(:relays, [:follow_activity_id], where: "follow_activity_id IS NOT NULL")
    create index(:relays, [:state])
  end
end
