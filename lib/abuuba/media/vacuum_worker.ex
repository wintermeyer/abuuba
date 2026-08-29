defmodule Abuuba.Media.VacuumWorker do
  @moduledoc """
  Drops copies of other people's media that nobody has looked at for a while.

  Daily. Remote media is a cache: it can be fetched again from the server it
  came from, which is what makes deleting it safe where deleting a local file
  would be deleting somebody's picture.

  Off unless an admin has set a retention. Somebody who has not chosen a number
  has not chosen to delete anything, and a server quietly discarding a year of
  images because a default said so is a bad surprise.
  """

  use Oban.Worker, queue: :media, max_attempts: 3

  require Logger

  alias Abuuba.Media
  alias Abuuba.Settings

  @impl Oban.Worker
  def perform(_job) do
    case retention_days() do
      days when days > 0 ->
        {:ok, count} = Media.vacuum_remote_media(days)

        if count > 0, do: Logger.info("dropped #{count} cached remote attachments")

        :ok

      _ ->
        :ok
    end
  end

  defp retention_days do
    case Settings.get("content_retention_days") do
      days when is_integer(days) -> days
      days when is_binary(days) -> String.to_integer(days)
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end
end
