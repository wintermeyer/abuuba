defmodule Abuuba.Statuses.PollExpiryWorker do
  @moduledoc """
  Runs `Abuuba.Statuses.PollExpiry` every minute.

  Every minute rather than scheduled per poll, because a job queued for a
  moment months away is a job that has to survive a redeploy, a queue purge
  and a poll being edited or deleted in between. A minute is close enough to
  "when it closed" for something whose whole purpose is that the answer is now
  in.
  """

  # `ingress` like the other minutely sweep (`ScheduledWorker`): milliseconds
  # of database work.
  use Oban.Worker, queue: :ingress, max_attempts: 3

  require Logger

  alias Abuuba.Statuses.PollExpiry

  @impl Oban.Worker
  def perform(_job) do
    {:ok, count} = PollExpiry.run()

    if count > 0, do: Logger.info("announced #{count} closed polls")

    :ok
  end
end
