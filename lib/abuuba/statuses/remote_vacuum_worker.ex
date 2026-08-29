defmodule Abuuba.Statuses.RemoteVacuumWorker do
  @moduledoc """
  Runs `Abuuba.Statuses.RemoteVacuum` nightly.

  At 04:15, half an hour after the media vacuum, so the two do not compete for
  the same disk on a server where both have a backlog. Both are off until an
  admin sets a retention.
  """

  # `media` with the other two disk sweeps: `RemoteVacuum.drop_files/1`
  # deletes the attachments' bytes itself, not just rows. The schedule
  # spacing, not the queue, is what keeps the sweeps from overlapping.
  use Oban.Worker, queue: :media, max_attempts: 3

  require Logger

  alias Abuuba.Settings
  alias Abuuba.Statuses.RemoteVacuum

  @impl Oban.Worker
  def perform(_job) do
    case retention_days() do
      days when days > 0 ->
        {:ok, count} = RemoteVacuum.run(days)

        if count > 0, do: Logger.info("dropped #{count} remote posts past their retention")

        :ok

      _ ->
        :ok
    end
  end

  # Read the same way the media vacuum reads its own: an admin form writes an
  # integer, an import may have written a string, and neither should be the
  # difference between sweeping and not.
  defp retention_days do
    case Settings.get("remote_post_retention_days") do
      days when is_integer(days) -> days
      days when is_binary(days) -> String.to_integer(days)
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end
end
