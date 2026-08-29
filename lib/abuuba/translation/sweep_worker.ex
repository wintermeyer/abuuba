defmodule Abuuba.Translation.SweepWorker do
  @moduledoc """
  Takes translation cache entries whose day has passed.

  Hourly, and one query when there is nothing to do. Without it the table grows
  with every distinct post anybody ever asked about, which is a slow leak
  rather than a bug and therefore one nobody notices until it is large.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  alias Abuuba.Translation

  @impl Oban.Worker
  def perform(_job) do
    Translation.sweep()
  end
end
