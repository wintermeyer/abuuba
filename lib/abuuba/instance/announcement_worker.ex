defmodule Abuuba.Instance.AnnouncementWorker do
  @moduledoc """
  Publishes announcements whose time has come.

  Every minute, which is finer than anybody schedules to. The sweep is one
  query returning nothing in the ordinary case.

  Publishing is a conditional update on `published`, so an announcement is
  published once even if two runs overlap, and anybody watching the stream is
  told at the moment it goes up rather than on their next poll.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  import Ecto.Query

  alias Abuuba.Instance.Announcement
  alias Abuuba.Repo
  alias Abuuba.Streaming

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    Announcement
    |> where([a], not a.published and not is_nil(a.scheduled_at) and a.scheduled_at <= ^now)
    |> Repo.all()
    |> Enum.each(&publish(&1, now))

    :ok
  end

  defp publish(announcement, now) do
    {count, _} =
      Announcement
      |> where([a], a.id == ^announcement.id and not a.published)
      |> Repo.update_all(set: [published: true, published_at: now, updated_at: now])

    if count == 1 do
      Streaming.publish_announcement(Repo.reload(announcement))
    end

    :ok
  end
end
