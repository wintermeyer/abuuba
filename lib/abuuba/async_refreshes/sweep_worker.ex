defmodule Abuuba.AsyncRefreshes.SweepWorker do
  @moduledoc """
  Takes the refresh rows nobody can read any more.

  A row per rebuild is a small leak that nobody notices until it is large, and
  the whole reason these carry an expiry rather than living in a cache is that
  something has to delete them. One query when there is nothing to do.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  alias Abuuba.AsyncRefreshes

  @impl Oban.Worker
  def perform(_job) do
    AsyncRefreshes.sweep()

    :ok
  end
end
