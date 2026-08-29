defmodule Abuuba.Exports.Worker do
  @moduledoc """
  Builds one archive.

  A zip holding `actor.json`, an `outbox.json` of every post in the shape other
  servers already receive them in, and the same CSVs the export page offers
  one at a time. Nothing here is a new format: the point of an archive is that
  something else can read it, and the something else is another Mastodon-shaped
  server.

  ## What is not in it

  The media files. An account with a thousand pictures is a zip nobody can
  build in a job and nobody can email about; `outbox.json` carries the URLs
  instead, which is what a reader needs to fetch them while this server is
  still up. That is a real limitation and the page says so rather than letting
  somebody find out after they have deleted their account.

  ## Posts are streamed by id

  A whole posting history does not go in a list. The outbox is written a page
  at a time straight into the file, so the memory this job needs does not grow
  with the account it is exporting.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.UserNotifier
  alias Abuuba.Exports
  alias Abuuba.Exports.Export
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Serializer
  alias Abuuba.Repo
  alias Abuuba.Statuses.Status

  @page 200

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"export_id" => id}}) do
    case Repo.get(Export, id) do
      nil -> :ok
      %Export{state: "done"} -> :ok
      export -> build(export)
    end
  end

  defp build(export) do
    account = Accounts.get_account(export.account_id)

    mark(export, %{state: "running"})

    if is_nil(account) do
      # The account went while the job waited. Nothing to export and nothing
      # wrong, so the row records that rather than retrying into the same hole.
      mark(export, %{state: "failed", error: "account is gone", finished_at: DateTime.utc_now()})
    else
      write(export, account)
    end

    :ok
  end

  defp write(export, account) do
    dir = Path.join(System.tmp_dir!(), "abuuba-export-#{export.id}")
    File.mkdir_p!(dir)

    try do
      File.write!(
        Path.join(dir, "actor.json"),
        Jason.encode!(Actor.render(account), pretty: true)
      )

      write_outbox(Path.join(dir, "outbox.json"), account)

      # The two the archive importer reads, alongside the CSVs another
      # server's settings importer reads. They are not the same file in a
      # different format: one is a spreadsheet of handles and the other an
      # OrderedCollection of post addresses. An archive written without these
      # was accepted by our own importer and reported no bookmarks and no
      # favourites, because it was reading `bookmarks.json` past a
      # `bookmarks.csv`.
      write_collection(Path.join(dir, "likes.json"), Exports.kept(account, :likes))
      write_collection(Path.join(dir, "bookmarks.json"), Exports.kept(account, :bookmarks))

      Enum.each(Exports.kinds(), fn kind ->
        File.write!(Path.join(dir, Exports.filename(kind)), Exports.csv(account, kind))
      end)

      finish(export, account, dir)
    rescue
      error ->
        mark(export, %{
          state: "failed",
          error: Exception.message(error),
          finished_at: DateTime.utc_now()
        })

        reraise error, __STACKTRACE__
    after
      File.rm_rf(dir)
    end
  end

  # Written as an ActivityStreams `OrderedCollection`, item by item, because
  # that is what a reader expects and because holding every post in memory to
  # encode them in one go is exactly what this job must not do.
  defp write_outbox(path, account) do
    file = File.open!(path, [:write, :utf8])

    try do
      IO.write(file, ~s({"@context":"https://www.w3.org/ns/activitystreams",))
      IO.write(file, ~s("type":"OrderedCollection","orderedItems":[))

      _written? =
        account.id
        |> stream_statuses()
        |> Enum.reduce(false, fn status, written? ->
          if written?, do: IO.write(file, ",")
          IO.write(file, Jason.encode!(Serializer.note(status)))

          true
        end)

      IO.write(file, "]}")
    after
      File.close(file)
    end
  end

  # Small enough to build in memory, unlike the outbox: these are addresses
  # rather than posts, and the cap on them is twenty thousand strings.
  defp write_collection(path, uris) do
    File.write!(
      path,
      Jason.encode!(%{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "OrderedCollection",
        "totalItems" => length(uris),
        "orderedItems" => uris
      })
    )
  end

  defp stream_statuses(account_id) do
    Stream.resource(
      fn -> 0 end,
      fn cursor ->
        Status
        |> where([s], s.account_id == ^account_id and s.id > ^cursor)
        |> where([s], is_nil(s.deleted_at))
        |> order_by([s], asc: s.id)
        |> limit(@page)
        |> preload([:account, :mentions])
        |> Repo.all()
        |> case do
          [] -> {:halt, cursor}
          rows -> {rows, List.last(rows).id}
        end
      end,
      & &1
    )
  end

  defp finish(export, account, dir) do
    filename = "abuuba-archive-#{account.username}-#{Date.utc_today()}.zip"
    path = Path.join(archive_dir(), "#{export.id}-#{random_suffix()}.zip")

    files = dir |> File.ls!() |> Enum.map(&to_charlist/1)
    {:ok, _zip} = :zip.create(to_charlist(path), files, cwd: to_charlist(dir))

    # Nobody but this server. The default would leave somebody's whole account
    # readable by every other account on the host, at a path whose only secret
    # is a sequential id.
    File.chmod!(path, 0o600)

    %{size: size} = File.stat!(path)

    mark(export, %{
      state: "done",
      path: path,
      filename: filename,
      size: size,
      finished_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), Export.lifetime_days() * 86_400, :second)
    })

    notify(account, export)
  end

  # Told rather than left to check. Building one can take minutes on a large
  # account, and a screen somebody has to keep reloading is a screen they close.
  defp notify(account, export) do
    case Accounts.get_user_by_account(account) do
      nil ->
        :ok

      user ->
        UserNotifier.deliver_export_ready(
          user,
          AbuubaWeb.Endpoint.url() <> "/settings/export/archives/#{export.id}/download"
        )
    end
  rescue
    _error -> :ok
  end

  # Outside the world-readable temp root, and named with something nobody can
  # guess. Configurable because a server with more than one node needs this on
  # shared storage rather than on whichever node happened to build it.
  # The location comes from `Abuuba.Exports`, which sweeps the same directory.
  # Making it here as well is how a sweep ends up looking somewhere nothing
  # writes to. Creating and locking it down stays here, because writing is
  # what needs the directory to exist.
  defp archive_dir do
    dir = Exports.archive_dir()

    File.mkdir_p!(dir)
    File.chmod(dir, 0o700)

    dir
  end

  defp random_suffix, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp mark(export, attrs) do
    export |> Export.changeset(attrs) |> Repo.update!()
  end
end
