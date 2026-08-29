defmodule Abuuba.Exports.SweepWorker do
  @moduledoc """
  Deletes archives nobody may download any more, and their files.

  A privacy job rather than housekeeping. What is on the disk is somebody's
  entire account in one file, and the only thing standing between that file and
  whoever next reads the disk is this running.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  alias Abuuba.Exports

  @impl Oban.Worker
  def perform(_job) do
    Exports.sweep()

    :ok
  end
end
