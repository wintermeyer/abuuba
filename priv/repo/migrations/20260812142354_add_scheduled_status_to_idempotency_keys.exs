defmodule Abuuba.Repo.Migrations.AddScheduledStatusToIdempotencyKeys do
  @moduledoc """
  A retry of a scheduled post has to find what the first attempt made.

  The key was recorded for an immediate post and dropped for a scheduled one,
  so a client that timed out while scheduling something ended up with two of
  them. `on_delete: :delete_all` for the same reason the status column has it:
  once the thing the key produced is gone, the key answers for nothing.
  """

  use Ecto.Migration

  def change do
    alter table(:idempotency_keys) do
      add :scheduled_status_id,
          references(:scheduled_statuses, type: :bigint, on_delete: :delete_all)
    end
  end
end
