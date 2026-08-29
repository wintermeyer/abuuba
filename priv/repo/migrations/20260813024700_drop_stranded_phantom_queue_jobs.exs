defmodule Abuuba.Repo.Migrations.DropStrandedPhantomQueueJobs do
  @moduledoc """
  Deletes the jobs two workers enqueued into queues no node ever ran.

  `PollExpiryWorker` named `:default` and `RemoteVacuumWorker` named
  `:maintenance`; neither queue is in the Oban config, so every one of their
  jobs sat in `available` forever -- the cron added a poll-expiry job per
  minute of uptime, and the pruner never touches unfinished jobs. The workers
  now enqueue into queues that run; this clears what the old ones stranded.

  Not reversible in any meaningful sense: rolling back cannot un-run jobs,
  and re-creating stuck rows helps nobody, so down is a no-op.
  """
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM oban_jobs
    WHERE queue IN ('default', 'maintenance')
      AND state IN ('available', 'scheduled', 'retryable')
    """)
  end

  def down, do: :ok
end
