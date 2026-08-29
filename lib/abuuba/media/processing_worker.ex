defmodule Abuuba.Media.ProcessingWorker do
  @moduledoc """
  Finishes an upload that was too big to finish inside the request.

  The work itself is `Abuuba.Media.Pipeline`; what is here is the state machine
  around it, because the API's status codes depend on it: a client polls
  `GET /api/v1/media/:id` and gets 206 until this marks the attachment
  complete.

  Its own queue, because transcoding a video is minutes of CPU and everything
  else in `:ingress` is milliseconds of database work. One long video would
  otherwise hold a slot that inbound federation needs.

  A failure is recorded rather than retried forever. A file that cannot be
  processed will not process on the fifth attempt either, and a client polling
  a 206 that never becomes a 200 waits for something that is never coming. The
  attempts that do happen are for the transient case: a machine that ran out of
  disk, or an ffmpeg that was killed.
  """

  use Oban.Worker, queue: :media, max_attempts: 3

  alias Abuuba.Media
  alias Abuuba.Media.Pipeline

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"attachment_id" => id}} = job) do
    case Media.get_attachment(id) do
      nil ->
        # Deleted while queued, which is ordinary: somebody changed their mind
        # about the post before it was ready.
        :ok

      attachment ->
        {:ok, attachment} = Media.set_processing(attachment, :in_progress)

        finish(attachment, job)
    end
  end

  # The last attempt records the failure; the earlier ones are allowed to fail
  # so Oban retries them, which is what makes a full disk recoverable and a
  # broken file final.
  defp finish(attachment, job) do
    case Pipeline.run(attachment) do
      {:ok, _attachment} ->
        :ok

      {:error, reason} ->
        if job.attempt >= job.max_attempts do
          :ok
        else
          {:error, reason}
        end
    end
  end

  @doc """
  Queues the work for an upload.
  """
  @spec enqueue(integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(attachment_id) do
    %{attachment_id: attachment_id} |> new() |> Oban.insert()
  end
end
