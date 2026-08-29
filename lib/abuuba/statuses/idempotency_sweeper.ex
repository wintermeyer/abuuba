defmodule Abuuba.Statuses.IdempotencySweeper do
  @moduledoc """
  Forgets idempotency keys too old to be anybody's retry.

  The table is a buffer rather than a log: it only has to outlast a client's
  retry, and left unswept it grows by one row per post forever.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 1

  alias Abuuba.Statuses

  @impl Oban.Worker
  def perform(_job) do
    Statuses.sweep_idempotency_keys()

    :ok
  end
end
