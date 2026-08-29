defmodule Mix.Tasks.Abuuba.Media do
  @shortdoc "Media operations: usage, remove orphaned, remove remote"

  @moduledoc """
  What is on the disk, and getting rid of what should not be.

      mix abuuba.media usage
      mix abuuba.media refresh --days 30
      mix abuuba.media remove-orphaned --dry-run
      mix abuuba.media remove-remote --days 30

  ## usage

  How much this server is holding and in what: local uploads against cached
  copies of other people's. Nearly always the answer to "why is the disk
  full", and nearly always the second number.

  ## remove-orphaned

  Attachment rows whose post is gone. A post deleted while its media was still
  being processed leaves one, and so does any interrupted upload; nothing else
  ever looks at them again.

  ## remove-remote

  Cached copies of other servers' media older than `--days`. They are a cache:
  what is deleted here still exists where it came from, and a reader who opens
  an old post fetches it again.

  ## refresh

  Fetches the cached copies whose file is no longer on this server, so a reader
  opening an old post does not wait for the round trip — and so a picture whose
  origin has since gone is here rather than nowhere.

  It is the same fetch the media proxy already does when a reader asks for a
  picture nobody has pulled yet; this only does it ahead of them, in bulk.
  `--days` narrows it to recent posts, which is usually what an admin means
  after a retention sweep took more than they intended, and `--limit` bounds a
  run against a server with a large backlog.
  """

  use Mix.Task

  import Ecto.Query

  alias Abuuba.Media
  alias Abuuba.Media.Attachment
  alias Abuuba.Media.Storage
  alias Abuuba.Ops
  alias Abuuba.Repo

  @commands ~w(usage refresh remove-orphaned remove-remote)

  @switches [days: :integer, limit: :integer, dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    Ops.start!()

    {opts, rest, _invalid} = OptionParser.parse(args, switches: @switches)

    case rest do
      ["usage" | _rest] -> usage()
      ["refresh" | _rest] -> refresh(opts)
      ["remove-orphaned" | _rest] -> remove_orphaned(opts)
      ["remove-remote" | _rest] -> remove_remote(opts)
      [command | _rest] -> Ops.unknown(command, @commands)
      [] -> Mix.raise("Say what to do: #{Enum.join(@commands, ", ")}")
    end
  end

  defp usage do
    local = bytes(from(a in Attachment, where: is_nil(a.remote_url) or a.remote_url == ""))
    remote = bytes(from(a in Attachment, where: not is_nil(a.remote_url) and a.remote_url != ""))

    Mix.shell().info("""
    Uploaded here: #{human(local)}
    Cached from elsewhere: #{human(remote)}
    Total: #{human(local + remote)}
    """)
  end

  defp refresh(opts) do
    stale =
      Media.uncached_remote(days: Keyword.get(opts, :days), limit: Keyword.get(opts, :limit))

    if Ops.dry_run?(opts) do
      Ops.report(true, length(stale), "attachment")
    else
      fetched =
        stale
        |> Enum.with_index(1)
        |> Enum.count(fn {attachment, index} ->
          Ops.progress(index, length(stale))

          match?({:ok, _body}, Media.cache_remote(attachment))
        end)

      Ops.progress_done()
      Ops.report(false, fetched, "attachment")

      if fetched < length(stale) do
        Mix.shell().info("#{length(stale) - fetched} could not be fetched and were left alone.")
      end
    end
  end

  defp remove_orphaned(opts) do
    query =
      from(a in Attachment,
        where: is_nil(a.status_id),
        where: a.inserted_at < ^DateTime.add(DateTime.utc_now(), -86_400, :second)
      )

    if Ops.dry_run?(opts) do
      Ops.report(true, Repo.aggregate(query, :count), "attachment")
    else
      attachments = Repo.all(query)

      attachments
      |> Enum.with_index(1)
      |> Enum.each(fn {attachment, index} ->
        Ops.progress(index, length(attachments))
        drop(attachment)
      end)

      Ops.progress_done()
      Ops.report(false, length(attachments), "attachment")
    end
  end

  defp remove_remote(opts) do
    days = Keyword.get(opts, :days, 30)

    if Ops.dry_run?(opts) do
      cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

      count =
        from(a in Attachment,
          where: not is_nil(a.remote_url) and a.remote_url != "",
          where: a.inserted_at < ^cutoff
        )
        |> Repo.aggregate(:count)

      Ops.report(true, count, "cached attachment")
    else
      {:ok, count} = Media.vacuum_remote_media(days)

      Ops.report(false, count, "cached attachment")
    end
  end

  ## Plumbing

  # A day old at least. An attachment with no post yet is the ordinary state of
  # one being uploaded right now, and deleting those would delete the picture
  # somebody is in the middle of posting.
  defp drop(attachment) do
    for style <- [:original, :small] do
      case Storage.key_for(attachment, style) do
        nil -> :ok
        key -> Storage.delete(key)
      end
    end

    Repo.delete(attachment, stale_error_field: :id)
  end

  # `sum` over no rows is null, and `Decimal` over some: both have to become an
  # integer before anything divides by 1024.
  defp bytes(query) do
    query
    |> select([a], sum(coalesce(a.file_file_size, 0) + coalesce(a.thumbnail_file_size, 0)))
    |> Repo.one()
    |> to_integer()
  end

  defp to_integer(nil), do: 0
  defp to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value), do: trunc(value)

  defp human(bytes) when bytes < 1024, do: "#{bytes} B"
  defp human(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp human(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"

  defp human(bytes), do: "#{Float.round(bytes / 1024 / 1024 / 1024, 2)} GB"
end
