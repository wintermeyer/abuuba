defmodule Abuuba.Statuses.CleanupWorker do
  @moduledoc """
  Runs everybody's standing instruction to delete their own old posts.

  One batch per person per run, oldest first, so a person with ten years of
  posts drains over a day or two rather than holding a job for an hour. Ordered
  by who was run longest ago, so nobody is starved by somebody with more to
  delete.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  alias Abuuba.Statuses.Cleanup

  @impl Oban.Worker
  def perform(_job) do
    Enum.each(Cleanup.subscribers(), &Cleanup.run/1)

    :ok
  end
end
