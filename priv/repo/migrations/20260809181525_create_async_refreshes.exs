defmodule Abuuba.Repo.Migrations.CreateAsyncRefreshes do
  @moduledoc """
  The state of work a client asked for and is waiting on.

  Some requests can only answer with what this server already has: a thread
  whose upper half lives on another server, a search whose remote half is still
  in flight. Rather than block the request until the network answers, the
  endpoint returns what it has along with the id of a refresh, and the client
  asks here whether more has arrived.

  In a table rather than in Redis, which is where Mastodon keeps it. abuuba's
  only datastore is Postgres, and a row that expires on a timestamp needs no
  second one. It costs a sweep, which is what `expires_at` is indexed for.
  """

  use Ecto.Migration

  def change do
    create table(:async_refreshes) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      # What is being refreshed, e.g. `context:1234`. Asking twice for the same
      # thing while the first is still running joins that one rather than
      # starting a second: two clients of the same account polling the same
      # thread is the ordinary case, not the exception.
      add :key, :string, null: false
      add :status, :string, null: false, default: "running"

      # Null where the work has nothing countable to report. The header omits
      # `result_count` entirely then, which is the difference between "none yet"
      # and "not that kind of refresh".
      add :result_count, :integer

      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:async_refreshes, [:account_id, :key],
             where: "status = 'running'",
             name: :async_refreshes_running_key_index
           )

    create index(:async_refreshes, [:expires_at])
  end
end
