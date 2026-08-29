defmodule Abuuba.Importer.Archive do
  @moduledoc """
  Reading the archive a fediverse server hands somebody of their own posts.

  Every Mastodon account can download one, and until now no server could read
  one back. That asymmetry is the thing worth fixing: an export nobody can
  import is a backup in name only, and it is the only copy somebody has of a
  server that has since closed.

  ## What is in one

  A zip, or a `.tar.gz` from an older server, laid out the way the export
  builder writes it:

      actor.json      the actor document, with the file names below in it
      outbox.json     an OrderedCollection of Create and Announce activities
      likes.json      an OrderedCollection of status addresses
      bookmarks.json  the same, for bookmarks
      avatar.png      whatever extension the original had
      header.png
      media_attachments/files/...   every attachment, at the path its post names

  The attachment addresses inside `outbox.json` are rewritten by the exporter
  to paths relative to the root of the archive, which is what makes a post and
  its pictures findable together without a network.

  ## Read, not trusted

  This is a file somebody uploaded, so nothing in it is believed.

  The size is checked twice: against what the archive says it will expand to,
  which is cheap and catches an honest large file, and against what it actually
  expanded to, because the first number is written by whoever built the
  archive. A zip claiming four kilobytes that unpacks four gigabytes fails the
  second check.

  Paths are refused by the runtime — `:zip` and `:erl_tar` both decline to write
  outside the directory they were handed — and refused again in `file/2`, where
  a path arrives from the same untrusted place by a different route.
  """

  # Somebody's whole posting history, with pictures. Large, but a zip that
  # claims to be four gigabytes when the upload was four megabytes is a zip
  # bomb rather than a busy poster.
  @max_bytes 2 * 1024 * 1024 * 1024

  @actor "actor.json"
  @outbox "outbox.json"
  @likes "likes.json"
  @bookmarks "bookmarks.json"

  defstruct [:root, :actor, :outbox, :likes, :bookmarks]

  @typedoc "An archive, unpacked into a directory this server owns."
  @type t :: %__MODULE__{
          root: String.t(),
          actor: map(),
          outbox: [map()],
          likes: [String.t()],
          bookmarks: [String.t()]
        }

  @doc """
  Unpacks an archive into `into` and reads the four documents out of it.

  The caller owns the directory afterwards and is expected to remove it: what
  is in there is a copy of everything somebody ever posted.
  """
  @spec open(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def open(path, into, opts \\ []) do
    with :ok <- unpack(path, into, Keyword.get(opts, :max_bytes, @max_bytes)),
         {:ok, actor} <- read_json(into, @actor) do
      {:ok,
       %__MODULE__{
         root: into,
         actor: actor,
         outbox: items(read_json(into, @outbox)),
         likes: uris(read_json(into, @likes)),
         bookmarks: uris(read_json(into, @bookmarks))
       }}
    end
  end

  @doc """
  The file one of the archive's own paths names, or `nil`.

  A path out of the archive is a path from a file somebody uploaded, so it is
  resolved against the root and then checked to be inside it. `../../etc` is
  not an attachment.
  """
  @spec file(t(), String.t() | nil) :: String.t() | nil
  def file(%__MODULE__{root: root}, path) when is_binary(path) and path != "" do
    resolved = root |> Path.join(path) |> Path.expand()

    if String.starts_with?(resolved, Path.expand(root) <> "/") and File.regular?(resolved) do
      resolved
    end
  end

  def file(_archive, _path), do: nil

  @doc """
  The name the account had on the server this archive came from.

  Read out of the actor document rather than out of the file name, and used
  only to tell somebody whose archive they are about to import into their own
  account.
  """
  @spec handle(t()) :: String.t() | nil
  def handle(%__MODULE__{actor: %{"preferredUsername" => name, "id" => id}})
      when is_binary(name) do
    case URI.parse(id || "") do
      %URI{host: host} when is_binary(host) -> "#{name}@#{host}"
      _no_host -> name
    end
  end

  def handle(_archive), do: nil

  ## Unpacking

  defp unpack(path, into, max_bytes) do
    with :ok <- File.mkdir_p(into) do
      case Path.extname(String.downcase(path)) do
        ".zip" -> unzip(path, into, max_bytes)
        extension when extension in [".gz", ".tgz"] -> untar(path, into, max_bytes)
        _unknown -> guess(path, into, max_bytes)
      end
    end
  end

  # The extension is a hint from whoever named the file, so a wrong one falls
  # back to trying both rather than refusing an archive that is perfectly
  # readable.
  defp guess(path, into, max_bytes) do
    case unzip(path, into, max_bytes) do
      :ok -> :ok
      {:error, _not_a_zip} -> untar(path, into, max_bytes)
    end
  end

  defp unzip(path, into, max_bytes) do
    with {:ok, total} <- zip_size(path),
         :ok <- within_limit(total, max_bytes),
         {:ok, _files} <- :zip.extract(to_charlist(path), [{:cwd, to_charlist(into)}]),
         :ok <- within_limit(unpacked_bytes(into), max_bytes) do
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _unreadable -> {:error, :unreadable_archive}
    end
  end

  # What is actually on the disk now. The number in the archive was written by
  # whoever built it, and an archive built to fill a disk lies about it.
  defp unpacked_bytes(into) do
    into
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reduce(0, fn path, total ->
      case File.stat(path) do
        {:ok, %{type: :regular, size: size}} -> total + size
        _not_a_file -> total
      end
    end)
  end

  # Asked before anything is written. A zip lists what it will expand to, and
  # an archive that says two gigabytes is one to refuse rather than one to
  # unpack and then measure.
  defp zip_size(path) do
    case :zip.list_dir(to_charlist(path)) do
      {:ok, entries} ->
        {:ok, Enum.reduce(entries, 0, &(&2 + entry_size(&1)))}

      _unreadable ->
        {:error, :unreadable_archive}
    end
  end

  defp entry_size({:zip_file, _name, info, _comment, _offset, _size}) do
    elem(info, 1)
  end

  defp entry_size(_comment), do: 0

  defp within_limit(total, max_bytes) when total <= max_bytes, do: :ok
  defp within_limit(_too_big, _max_bytes), do: {:error, :archive_too_large}

  defp untar(path, into, max_bytes) do
    case :erl_tar.extract(to_charlist(path), [:compressed, {:cwd, to_charlist(into)}]) do
      :ok -> within_limit(unpacked_bytes(into), max_bytes)
      _unreadable -> {:error, :unreadable_archive}
    end
  end

  ## Reading

  defp read_json(root, name) do
    with path when is_binary(path) <- root |> Path.join(name) |> existing(),
         {:ok, contents} <- File.read(path),
         {:ok, document} <- Jason.decode(contents) do
      {:ok, document}
    else
      _missing_or_broken -> {:error, :unreadable_archive}
    end
  end

  defp existing(path), do: if(File.regular?(path), do: path)

  # An OrderedCollection, or the plain list an older exporter wrote. Anything
  # else is an empty one: a missing likes file is somebody who never favourited
  # anything, not a broken archive.
  defp items({:ok, %{"orderedItems" => items}}) when is_list(items), do: items
  defp items({:ok, items}) when is_list(items), do: items
  defp items(_none), do: []

  defp uris(document) do
    document |> items() |> Enum.filter(&is_binary/1)
  end
end
