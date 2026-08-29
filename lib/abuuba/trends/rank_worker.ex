defmodule Abuuba.Trends.RankWorker do
  @moduledoc """
  Recomputes the rankings and throws away counts too old to matter.

  Every five minutes. Often enough that a trend appears while it is still one,
  rarely enough that the work is a few hundred rows rather than a running total
  maintained on every post.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  alias Abuuba.Trends

  @impl Oban.Worker
  def perform(_job) do
    :ok = Trends.rank()
    :ok = Trends.sweep()

    :ok
  end
end
