defmodule Abuuba.Exports do
  @moduledoc """
  Taking your account with you.

  Two shapes, because two different things are being asked for.

  A **CSV** is a list somebody wants to feed back into another server: who they
  follow, who they block, who they mute, their lists, their blocked domains,
  their bookmarks, their filters. Small, immediate, and in exactly the format
  `Abuuba.Imports` reads, so an export from here is an import there and the round
  trip is the point.

  An **archive** is everything else: the profile and every post, as JSON. It is
  built by a job because it walks a whole account, and it is the most sensitive
  single object this server ever writes, so it expires.

  ## The CSVs answer straight away

  A list of follows is a few hundred rows. Queueing that would mean an email,
  a job and a screen that says "we will let you know", for a file that takes
  fifteen milliseconds to build.

  ## One archive at a time, and not many

  Mastodon allows one archive a week. The same here: an archive is expensive to
  build and dangerous to leave lying around, and somebody who needs a second
  one within the week can still take the CSVs.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Exports.Export
  alias Abuuba.Exports.Worker
  alias Abuuba.Federation.Serializer
  alias Abuuba.Filters
  alias Abuuba.Lists
  alias Abuuba.Relationships
  alias Abuuba.Relationships.Follow
  alias Abuuba.Relationships.Mute
  alias Abuuba.Repo
  alias Abuuba.Statuses

  @kinds ~w(follows blocks mutes lists domain_blocks bookmarks filters)

  # What the importer reads back, and what Mastodon writes. The header matters:
  # its own importer keys on these names, so a file from here has to carry them
  # even where the value is always the default.
  @headers %{
    "follows" => ["Account address", "Show boosts", "Notify on new posts", "Languages"],
    "blocks" => ["Account address"],
    "mutes" => ["Account address", "Hide notifications"],
    "domain_blocks" => ["#domain"],
    "bookmarks" => ["#uri"],
    "lists" => ["List name", "Account address"],
    "filters" => ["Title", "Context", "Action", "Keyword", "Whole word"]
  }

  @doc """
  The kinds of list somebody may export.
  """
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  The filename a browser should save one under.
  """
  @spec filename(String.t()) :: String.t()
  def filename(kind), do: kind <> ".csv"

  @doc """
  One list, as CSV.

  `nil` for a kind this server does not export, so a caller can turn that into
  a 404 rather than an empty file somebody would take for an empty account.
  """
  @spec csv(Account.t(), String.t()) :: String.t() | nil
  def csv(%Account{} = account, kind) when kind in @kinds do
    encode(Map.fetch!(@headers, kind), rows(account, kind))
  end

  def csv(_account, _kind), do: nil

  ## Rows

  # A cap rather than everything, because these queries have no cursor here and
  # an unbounded one on a machine account would build a list nothing can hold.
  # High enough that no ordinary account reaches it, and the archive is the
  # answer for one that does.
  @cap 20_000

  @doc """
  The addresses of the posts somebody kept, for the archive.

  The CSVs are what another server's settings importer reads. These two are
  what an *archive* importer reads -- ours and Mastodon's alike -- and they are
  a different shape for a different job: an OrderedCollection of post
  addresses rather than a spreadsheet.

  Both belong in the zip. Without these, an archive from here opened by the
  importer here reported no bookmarks and no favourites, because the exporter
  wrote `bookmarks.csv` and the importer reads `bookmarks.json`.
  """
  @spec kept(Account.t(), :likes | :bookmarks) :: [String.t()]
  def kept(%Account{} = account, :likes) do
    account
    |> Statuses.favourites(%{limit: @cap})
    |> Enum.map(&Serializer.status_uri(&1.status))
  end

  def kept(%Account{} = account, :bookmarks) do
    account
    |> Statuses.bookmarks(%{limit: @cap})
    |> Enum.map(&Serializer.status_uri(&1.status))
  end

  # The edge rows, not just the accounts. Writing the defaults instead would
  # make the round trip actively harmful: importing the file elsewhere would
  # switch boosts back on for everybody who had turned them off, and drop every
  # per-follow notification somebody had asked for.
  defp rows(account, "follows") do
    Follow
    |> edges(account)
    |> Enum.map(fn {follow, target} ->
      [
        Account.acct(target),
        to_string(follow.show_reblogs),
        to_string(follow.notify),
        follow.languages |> List.wrap() |> Enum.join(", ")
      ]
    end)
  end

  defp rows(account, "blocks") do
    account |> Relationships.blocked_accounts(%{limit: @cap}) |> Enum.map(&[Account.acct(&1)])
  end

  defp rows(account, "mutes") do
    Mute
    |> edges(account)
    |> Enum.map(fn {mute, target} ->
      [Account.acct(target), to_string(mute.hide_notifications)]
    end)
  end

  defp rows(account, "domain_blocks") do
    account |> Relationships.blocked_domains(%{limit: @cap}) |> Enum.map(&[&1])
  end

  defp rows(account, "bookmarks") do
    account
    |> Statuses.bookmarks(%{limit: @cap})
    |> Enum.map(&[Serializer.status_uri(&1.status)])
  end

  # One row per member rather than one per list, because a list with no rows is
  # a list with no members and CSV has no way to say otherwise. Mastodon's
  # importer reads it the same way.
  defp rows(account, "lists") do
    account
    |> Lists.all()
    |> Enum.flat_map(fn list ->
      list |> Lists.members(%{limit: @cap}) |> Enum.map(&[list.title, Account.acct(&1)])
    end)
  end

  # One row per keyword, for the same reason.
  defp rows(account, "filters") do
    account
    |> Filters.all()
    |> Enum.flat_map(fn filter ->
      Enum.map(filter.keywords, fn keyword ->
        [
          filter.title,
          Enum.join(filter.context, " "),
          filter.filter_action,
          keyword.keyword,
          to_string(keyword.whole_word)
        ]
      end)
    end)
  end

  # One query for the edge and the account it points at, because both halves
  # of every row here come from the edge rather than only from the target.
  defp edges(schema, account) do
    schema
    |> where([e], e.account_id == ^account.id)
    |> join(:inner, [e], a in Account, on: a.id == e.target_account_id)
    |> order_by([e], desc: e.id)
    |> limit(@cap)
    |> select([e, a], {e, a})
    |> Repo.all()
  end

  ## Archives

  @doc """
  The archives one account has asked for, newest first.
  """
  @spec archives(Account.t() | integer()) :: [Export.t()]
  def archives(%Account{id: id}), do: archives(id)

  def archives(account_id) do
    Export
    |> where([e], e.account_id == ^account_id)
    |> order_by([e], desc: e.id)
    |> limit(10)
    |> Repo.all()
  end

  @doc """
  The most recent one, or `nil`.
  """
  @spec latest(Account.t() | integer()) :: Export.t() | nil
  def latest(account), do: account |> archives() |> List.first()

  @doc """
  One archive belonging to this account, or `nil`.

  Scoped to the account rather than fetched by id: an archive is somebody's
  whole account in one file, so an id somebody can guess must not be an id
  somebody can download.
  """
  @spec get(Account.t() | integer(), term()) :: Export.t() | nil
  def get(%Account{id: id}, export_id), do: get(id, export_id)

  def get(account_id, export_id) do
    # Bounded, not merely numeric: `Integer.parse/1` happily returns a number
    # too large for the column and Postgrex then raises on encoding it, turning
    # a bad id in a URL into a 500 anybody can trigger.
    case Integer.parse(to_string(export_id)) do
      {id, ""} when id > 0 and id < 9_223_372_036_854_775_808 ->
        Repo.get_by(Export, id: id, account_id: account_id)

      _ ->
        nil
    end
  end

  @doc """
  Asks for a new archive.

  Refused where one is already being built, and where one was built recently
  enough that the answer would be the same file.
  """
  @spec request(Account.t()) ::
          {:ok, Export.t()} | {:error, :in_progress | {:too_soon, DateTime.t()}}
  def request(%Account{} = account) do
    case latest(account) do
      %Export{state: state} when state in ["pending", "running"] ->
        {:error, :in_progress}

      %Export{state: state, inserted_at: at} = export when state in ["done", "expired"] ->
        if fresh?(export), do: {:error, {:too_soon, next_allowed(at)}}, else: insert(account)

      _ ->
        insert(account)
    end
  end

  @doc """
  How long somebody must wait between archives.
  """
  @spec cooldown_days() :: pos_integer()
  def cooldown_days, do: Export.cooldown_days()

  @doc """
  When this account may ask for another one, or `nil` if now.
  """
  @spec next_allowed(Account.t() | DateTime.t() | nil) :: DateTime.t() | nil
  def next_allowed(nil), do: nil

  def next_allowed(%Account{} = account) do
    case latest(account) do
      %Export{state: state, inserted_at: at} = export when state in ["done", "expired"] ->
        if fresh?(export), do: next_allowed(at)

      _ ->
        nil
    end
  end

  def next_allowed(%DateTime{} = at),
    do: DateTime.add(at, Export.cooldown_days() * 86_400, :second)

  @doc """
  Whether an archive is still downloadable.
  """
  @spec downloadable?(Export.t()) :: boolean()
  def downloadable?(%Export{state: "done", expires_at: expires_at, path: path})
      when is_binary(path) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  def downloadable?(_export), do: false

  @doc """
  Deletes the archives nobody may download any more, and their files.

  A privacy job rather than a housekeeping one: what is being deleted is
  somebody's entire account sitting in one file on a disk.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    now = DateTime.utc_now()

    Export
    |> where([e], e.expires_at <= ^now)
    |> Repo.all()
    |> Enum.map(&discard/1)
    |> length()
    |> Kernel.+(release_stuck(now))
  end

  # A job that was killed rather than raised — a deploy, a node restart, an
  # Oban timeout — never reaches the branch that marks the row failed, and a
  # row stuck on `running` blocks this account from ever asking again. Nothing
  # else would notice, because a stuck row has no `expires_at` for the sweep
  # above to find.
  defp release_stuck(now) do
    cutoff = DateTime.add(now, -Export.stall_hours() * 3600, :second)

    stuck =
      Export
      |> where([e], e.state in ["pending", "running"] and e.updated_at < ^cutoff)
      |> select([e], e.id)
      |> Repo.all()

    # Before the rows are marked, because after that they look like any other
    # failure. The archive is written and the row is told about it second, so a
    # job killed in between leaves a zip that no row points at -- and the sweep
    # above only finds rows with an `expires_at`, which a stuck one never had.
    # What is left behind is one person's entire account in one file.
    Enum.each(stuck, &remove_archives/1)

    {released, _} =
      Export
      |> where([e], e.state in ["pending", "running"] and e.updated_at < ^cutoff)
      |> Repo.update_all(set: [state: "failed", error: "did not finish", updated_at: now])

    released
  end

  # By id rather than by the recorded path: the path is the thing the killed
  # job never got to write down. The name the builder chooses always starts
  # with the export's id, so that is what identifies the file when the row
  # cannot.
  defp remove_archives(export_id) do
    archive_dir()
    |> Path.join("#{export_id}-*.zip")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)
  end

  @doc """
  Where the archives live.

  Shared with `Abuuba.Exports.Worker`, which writes them: two answers to "where
  is the archive directory" is how a sweep ends up cleaning a directory
  nothing writes to.
  """
  @spec archive_dir() :: String.t()
  def archive_dir do
    Application.get_env(:abuuba, :export_dir) || Path.join(System.tmp_dir!(), "abuuba-exports")
  end

  @doc """
  Takes the file away and keeps the row.

  The row is what the weekly limit is computed from, so deleting it would reset
  the limit two days after every archive — which is the lifetime, not the
  cooldown. What has to go is the file; what has to stay is the fact that one
  was built.
  """
  @spec discard(Export.t()) :: :ok
  def discard(%Export{} = export) do
    if is_binary(export.path), do: File.rm(export.path)

    export
    |> Export.changeset(%{path: nil, size: nil, expires_at: nil, state: "expired"})
    |> Repo.update()

    :ok
  end

  @doc """
  Discards every archive an account has, files and all.

  For an account being closed. The rows are `delete_all`, so the cascade takes
  them and leaves the zips: the sweep that removes a file only ever sees rows
  past their expiry, and these are gone before it looks. An export is somebody's
  whole account in one file, kept for two days for exactly that reason, and
  closing the account is the moment that most needs to be honoured rather than
  the one that turns two days into for ever.
  """
  @spec discard_for_account(Account.t() | integer()) :: {:ok, non_neg_integer()}
  def discard_for_account(%Account{id: id}), do: discard_for_account(id)

  def discard_for_account(account_id) do
    exports = Export |> where([e], e.account_id == ^account_id) |> Repo.all()

    Enum.each(exports, &discard/1)

    {:ok, length(exports)}
  end

  ## Plumbing

  defp insert(account) do
    with {:ok, export} <-
           %Export{}
           |> Export.changeset(%{account_id: account.id, state: "pending"})
           |> Repo.insert() do
      %{export_id: export.id} |> Worker.new() |> Oban.insert()

      {:ok, export}
    end
  end

  defp fresh?(%Export{inserted_at: at}) do
    DateTime.compare(next_allowed(at), DateTime.utc_now()) == :gt
  end

  # RFC 4180 quoting, applied to every field rather than only the ones that
  # need it. A display name with a comma in it is the ordinary case, not the
  # exception, and a reader that has to guess is a reader that gets it wrong.
  defp encode(header, rows) do
    [header | rows]
    |> Enum.map_join("\r\n", fn row -> Enum.map_join(row, ",", &field/1) end)
    |> Kernel.<>("\r\n")
  end

  defp field(value) do
    "\"" <> String.replace(to_string(value), "\"", "\"\"") <> "\""
  end
end
