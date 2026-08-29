defmodule Abuuba.Statuses.ScheduledWorker do
  @moduledoc """
  Publishes the posts whose time has come.

  Without this, scheduling is a feature that stores something and never acts on
  it, which is worse than not offering it: somebody writes a post, is told it
  will go out at nine, and it never does.

  Runs on a schedule of its own rather than one timer per post. A timer per
  post does not survive a restart, and a queue of thousands of them is a queue
  of thousands of processes waiting to do nothing.

  Each post is published in its own transaction, so one that fails validation
  because the world moved on (its reply target was deleted, say) does not hold
  up everything else that was due at the same minute.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  require Logger

  alias Abuuba.Statuses

  @impl Oban.Worker
  def perform(_job) do
    Enum.each(Statuses.due_schedules(), &publish/1)

    :ok
  end

  defp publish(scheduled) do
    case Statuses.publish_scheduled(scheduled) do
      {:ok, _status} ->
        :ok

      {:error, changeset} ->
        # Dropped rather than retried forever. The person's post cannot be
        # published as written, and the schedule is gone either way; leaving it
        # would mean trying again every minute for the rest of the server's
        # life.
        Logger.warning(
          "scheduled status #{scheduled.id} could not be published: #{inspect(changeset.errors)}"
        )

        Statuses.cancel_schedule(scheduled)
    end
  end
end
