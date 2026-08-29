defmodule Abuuba.Imports do
  @moduledoc """
  Reading somebody's own archive back into their account.

  Every fediverse server hands its users a zip of everything they posted, and
  none of them can read one back. That asymmetry is what this fixes: an export
  nobody can import is a backup in name only, and for somebody whose server has
  closed it is the only copy that still exists.

  ## What can be carried over, and what cannot

  The posts, their pictures, their dates, and the favourites and bookmarks that
  can still be found. Not the addresses: a post that lived at
  `https://old.example/users/alice/statuses/1` cannot live there again, because
  this server is not that domain. Every imported post gets an address here and
  keeps its original date, so a profile reads in the right order even though
  every permalink is new.

  Not the followers either. A follow is an agreement between two servers and
  one of them is gone; the people who followed the old account have to follow
  this one. Saying so plainly beats letting somebody discover it a week later.

  ## Old posts stay out of everybody's way

  An imported post is written now and was published years ago, and everything
  downstream of a new post assumes those are the same moment. So imported posts
  do not go into anybody's home timeline, do not federate, do not trend and do
  not appear in a live timeline. They sit on the author's profile, in the order
  they were written, which is what somebody importing an archive is asking for.

  ## One at a time, in the background

  Reading years of posts takes minutes. It is a job, its progress is a row, and
  the row is what the settings page reads — so closing the tab does not stop it
  and coming back shows where it got to.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.ResolveStatus
  alias Abuuba.Importer.Archive
  alias Abuuba.Imports.ArchivePost
  alias Abuuba.Imports.CSV
  alias Abuuba.Imports.CSVRows
  alias Abuuba.Imports.Run
  alias Abuuba.Imports.Worker
  alias Abuuba.Repo
  alias Abuuba.Statuses
  alias Ecto.Multi

  @topic "archive_import"

  # A zip of somebody's posting history with the pictures in it. Generous,
  # because the alternative is telling somebody with ten years of photographs
  # that their own archive is too big for them.
  @max_upload_bytes 2 * 1024 * 1024 * 1024

  # A list of twenty thousand handles is under a megabyte. Twenty is generous
  # for a file of one column, and small enough that nothing has to stream it.
  @max_list_bytes 20 * 1024 * 1024

  @doc """
  The largest archive an upload may be.
  """
  @spec max_upload_bytes() :: pos_integer()
  def max_upload_bytes, do: @max_upload_bytes

  @doc """
  The largest exported list an upload may be.
  """
  @spec max_list_bytes() :: pos_integer()
  def max_list_bytes, do: @max_list_bytes

  @doc """
  Moves an uploaded file somewhere that outlives the request.

  LiveView deletes the file it wrote as soon as the upload is consumed, and the
  job that reads it starts after that. This is the copy the job opens, and the
  job removes it when it is done.
  """
  @spec keep(String.t(), String.t()) :: String.t()
  def keep(path, filename) do
    kept =
      Path.join(
        System.tmp_dir!(),
        "abuuba-archive-upload-#{System.unique_integer([:positive])}#{Path.extname(filename)}"
      )

    File.cp!(path, kept)

    kept
  end

  @doc """
  Starts an import of an uploaded file.

  The file is already on this server's disk; the row is what says whose it is,
  what kind of thing it holds, and where it went. Refuses a second one while
  the first is still going: two would race over the same account and neither
  progress bar would mean anything.

  `kind` is `"archive"` or one of the CSV lists. `mode` is `"merge"` or
  `"overwrite"`, and only means anything for a list.
  """
  @spec start(Account.t(), map()) :: {:ok, Run.t()} | {:error, term()}
  def start(%Account{id: account_id}, %{path: path} = upload) do
    attrs = %{
      account_id: account_id,
      path: path,
      filename: Map.get(upload, :filename),
      kind: to_string(Map.get(upload, :kind, "archive")),
      mode: to_string(Map.get(upload, :mode, "merge")),
      state: "pending"
    }

    Multi.new()
    |> Multi.insert(:run, Run.changeset(%Run{}, attrs))
    |> Multi.run(:job, fn _repo, %{run: run} -> Worker.enqueue(run) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{run: run}} -> {:ok, run}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  The most recent import for an account, running or finished.
  """
  @spec latest(Account.t() | integer()) :: Run.t() | nil
  def latest(%Account{id: account_id}), do: latest(account_id)

  def latest(account_id) do
    Run
    |> where([i], i.account_id == ^account_id)
    |> order_by([i], desc: i.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  One import by id.
  """
  @spec get(integer()) :: Run.t() | nil
  def get(id), do: Repo.get(Run, id)

  @doc """
  Where progress is announced, so a settings page can watch one.
  """
  @spec topic(Account.t() | integer()) :: String.t()
  def topic(%Account{id: account_id}), do: topic(account_id)
  def topic(account_id), do: "#{@topic}:#{account_id}"

  @doc """
  Subscribes the caller to one account's import.
  """
  @spec subscribe(Account.t() | integer()) :: :ok | {:error, term()}
  def subscribe(account), do: Phoenix.PubSub.subscribe(Abuuba.PubSub, topic(account))

  @doc """
  Reads an archive into the account that uploaded it.

  Every item is attempted; one that cannot be read is recorded and the rest
  continue. An archive is somebody's whole history and stopping the lot because
  one post from 2017 has a missing picture would be the wrong trade.
  """
  @spec run(Run.t()) :: {:ok, Run.t()} | {:error, term()}
  def run(%Run{kind: "archive"} = run), do: run_archive(run)
  def run(%Run{} = run), do: run_list(run)

  defp run_archive(archive_import) do
    account = Repo.get(Account, archive_import.account_id)
    into = unpacked_into(archive_import)

    try do
      case Archive.open(archive_import.path, into) do
        {:ok, archive} -> import_all(archive_import, account, archive)
        {:error, reason} -> fail(archive_import, reason)
      end
    after
      # Whatever happened: a copy of everything somebody ever posted does not
      # stay on this disk.
      File.rm_rf(into)
      File.rm(archive_import.path)
    end
  end

  # A list is small enough to read into memory and slow enough to apply that
  # every row is its own attempt: a follow list from a server that closed names
  # accounts on a hundred others, and some of them will be gone.
  defp run_list(run) do
    account = Repo.get(Account, run.account_id)

    try do
      with {:ok, contents} <- File.read(run.path),
           {:ok, kind, rows} <- CSV.read(contents, run.filename || "") do
        apply_rows(run, account, kind, rows)
      else
        {:error, reason} -> fail(run, reason)
      end
    after
      File.rm(run.path)
    end
  end

  defp apply_rows(run, account, kind, rows) do
    run = progress(run, %{state: "running", total: length(rows), kind: to_string(kind)})

    # Before the first row, so a run that stops halfway does not leave somebody
    # following nobody.
    if run.mode == "overwrite", do: CSVRows.clear(kind, account)

    rows
    |> Enum.reduce(run, fn row, acc ->
      case CSVRows.apply(kind, account, row) do
        :ok -> advance(acc, 1)
        {:error, reason} -> failed(acc, describe(kind, row), reason)
      end
    end)
    |> finish()
  end

  # Named by what the row was about, which is the only thing somebody reading a
  # failure report can act on.
  defp describe(:domain_blocking, row), do: row[:domain] || "a domain"
  defp describe(:bookmarks, row), do: row[:uri] || "a post"
  defp describe(:filters, row), do: row[:title] || row[:keyword] || "a filter"
  defp describe(_accounts, row), do: row[:acct] || "an account"

  ## Running

  defp import_all(archive_import, account, archive) do
    total = length(archive.outbox) + length(archive.likes) + length(archive.bookmarks)

    archive_import = progress(archive_import, %{state: "running", total: total})

    archive_import
    |> import_posts(account, archive)
    |> import_reactions(account, archive)
    |> finish()
  end

  defp import_posts(archive_import, account, archive) do
    Enum.reduce(archive.outbox, archive_import, fn activity, acc ->
      case ArchivePost.import(account, activity, archive) do
        {:ok, _status} -> advance(acc, 1)
        :skip -> advance(acc, 0)
        {:error, reason} -> failed(acc, ArchivePost.describe(activity), reason)
      end
    end)
  end

  # Favourites and bookmarks name posts by address, and an address is only
  # useful if the post is still somewhere. Fetching one goes through the same
  # door every other outbound request does, so a server that is down or slow
  # costs this import one failed line rather than an hour.
  defp import_reactions(archive_import, account, archive) do
    archive_import
    |> react(account, archive.likes, &Statuses.favourite/2, "favourite")
    |> react(account, archive.bookmarks, &Statuses.bookmark/2, "bookmark")
  end

  defp react(archive_import, account, uris, act, what) do
    Enum.reduce(uris, archive_import, fn uri, acc ->
      with {:ok, status} <- ResolveStatus.resolve(uri),
           {:ok, _done} <- act.(account, status) do
        advance(acc, 1)
      else
        _unreachable -> failed(acc, "#{what} #{uri}", :could_not_be_fetched)
      end
    end)
  end

  ## The row

  defp advance(archive_import, imported) do
    progress(archive_import, %{
      done: archive_import.done + 1,
      imported: archive_import.imported + imported
    })
  end

  # Kept, but not without end: an archive whose every post fails would
  # otherwise put a hundred thousand lines in one row and in one page.
  @max_failures 200

  defp failed(archive_import, what, reason) do
    failures = archive_import.failures

    failures =
      if length(failures) < @max_failures do
        failures ++ [%{"what" => what, "reason" => to_string(reason)}]
      else
        failures
      end

    progress(archive_import, %{done: archive_import.done + 1, failures: failures})
  end

  defp finish(archive_import) do
    {:ok, progress(archive_import, %{state: "finished", finished_at: DateTime.utc_now()})}
  end

  defp fail(archive_import, reason) do
    finished =
      progress(archive_import, %{
        state: "failed",
        finished_at: DateTime.utc_now(),
        failures: [%{"what" => "the archive", "reason" => to_string(reason)}]
      })

    {:ok, finished}
  end

  defp progress(archive_import, attrs) do
    {:ok, updated} =
      archive_import
      |> Run.progress_changeset(attrs)
      |> Repo.update()

    announce(updated)

    updated
  end

  # Announced on every change rather than every row: a progress bar that moves
  # once a second is a progress bar, and one that broadcasts per post is a
  # thousand messages nobody reads.
  defp announce(archive_import) do
    Phoenix.PubSub.broadcast(
      Abuuba.PubSub,
      topic(archive_import.account_id),
      {:archive_import, archive_import}
    )
  end

  defp unpacked_into(%Run{id: id}) do
    Path.join(System.tmp_dir!(), "abuuba-archive-#{id}")
  end
end
