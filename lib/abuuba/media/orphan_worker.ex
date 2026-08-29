defmodule Abuuba.Media.OrphanWorker do
  @moduledoc """
  Deletes uploads nobody posted, and the files behind them.

  `Abuuba.Media.unattached_before/1` has always described itself as "what the
  storage sweeper collects". There was no sweeper: the only thing that
  reclaimed an orphan was `mix abuuba.media remove-orphaned`, typed by an admin
  who had noticed the disk filling. So every upload somebody started and
  abandoned, and every attachment orphaned by a delete that nulled its
  `status_id`, stayed on the disk for good.

  Daily, at 04:45, after both retention vacuums so three sweeps with a backlog
  do not compete for the same disk.

  ## A day old, not an hour

  An attachment with no post is the ordinary state of one being uploaded right
  now. The compose box holds a picture between the upload and the post, and
  somebody writing carefully takes minutes over it. A day is far longer than
  anybody spends and short enough that an abandoned upload is not a permanent
  resident.

  ## Unlike the retention vacuums, this needs no setting

  Those delete things somebody chose to keep, so they are off until an admin
  says otherwise. An upload with no post and no owner is not something anybody
  chose to keep: it is a file the server is holding by accident.
  """

  use Oban.Worker, queue: :media, max_attempts: 3

  require Logger

  alias Abuuba.Media

  # A ceiling per run, for the same reason the other sweeps have one: a server
  # that has never swept has a backlog, and clearing it over a few nights beats
  # one long run holding a transaction open.
  @per_run 2_000
  @age_seconds 86_400

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@age_seconds, :second)

    count =
      cutoff
      |> Media.unattached_before()
      |> Enum.take(@per_run)
      |> Enum.reduce(0, fn attachment, taken ->
        Media.drop_stored_files(attachment)

        case Abuuba.Repo.delete(attachment, stale_error_field: :id) do
          {:ok, _} -> taken + 1
          _already_gone -> taken
        end
      end)

    if count > 0, do: Logger.info("dropped #{count} orphaned uploads")

    :ok
  end
end
