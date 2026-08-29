defmodule Abuuba.Webhooks.SweepWorker do
  @moduledoc """
  Deletes webhook delivery rows past their day.

  The log answers "is this working" and "when did it stop". Neither question
  reaches back further than a week, and a row per event per webhook adds up
  quickly on a busy server.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  alias Abuuba.Webhooks

  @impl Oban.Worker
  def perform(_job) do
    Webhooks.sweep()

    :ok
  end
end
