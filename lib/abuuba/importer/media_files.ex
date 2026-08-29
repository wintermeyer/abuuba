defmodule Abuuba.Importer.MediaFiles do
  @moduledoc """
  The files themselves, moved into place under the paths the rows already name.

  abuuba lays media out the way Mastodon does — `media_attachments/files/` split
  into three-digit groups by id, then the style, then the file name — and it
  does so deliberately, for exactly this: a takeover copies the tree and every
  row that named a file still names it.

  ## Only what this server holds

  Remote media is a cache. It can be fetched again from the server it came
  from, it is usually the larger half of the disk, and copying it means moving
  gigabytes that the first cache sweep would delete anyway. The `cache/` prefix
  is what marks it on both sides, so it is skipped by name.

  ## Copying, not moving

  The source's tree is left exactly as it was. A takeover that is being
  rehearsed has to be repeatable, and an import that consumed its own input
  could only ever be run once.

  ## Interruptible

  A file already at the destination with the same size is left alone, so a
  second run continues rather than starting over. Size rather than a checksum:
  reading every byte of a terabyte to find out it is the same terabyte is the
  cost this is trying to avoid, and nothing is writing to the source.
  """

  @behaviour Abuuba.Importer.Step

  alias Abuuba.Media.Attachment
  alias Abuuba.Media.Storage
  alias Abuuba.Media.Storage.Local
  alias Abuuba.Repo

  import Ecto.Query

  # The directories a Mastodon media root has that hold anything this server
  # will serve. Anything else under the root is somebody else's business.
  @trees ~w(media_attachments custom_emojis preview_cards site_uploads accounts)

  @impl Abuuba.Importer.Step
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts) do
    case root(opts) do
      nil -> :ok
      source -> copy_trees(source, opts)
    end
  end

  @doc """
  Says so when the media root cannot be read.

  Checked before anything is written, because a takeover that copies every row
  and no files is one where every avatar and every attachment is a broken image
  and nobody notices until somebody scrolls.
  """
  @impl Abuuba.Importer.Step
  @spec check(keyword()) :: [Abuuba.Importer.Step.problem()]
  def check(opts) do
    case root(opts) do
      nil ->
        []

      source ->
        if Enum.any?(@trees, &File.dir?(Path.join(source, &1))) do
          []
        else
          [
            %{
              key: "media_root",
              detail:
                "#{source} has none of #{Enum.join(@trees, ", ")} in it; that is not a Mastodon media root, and an import would copy no files at all"
            }
          ]
        end
    end
  end

  @doc """
  Takes a sample of attachments and asks whether their files are really there.

  A count of copied files proves nothing about whether the rows point at them.
  This asks the question the way a browser will: through the storage layer, at
  the key the row produces.
  """
  @impl Abuuba.Importer.Step
  @spec verify(keyword()) :: [Abuuba.Importer.Step.verification()]
  def verify(_opts) do
    sample =
      Attachment
      # An empty string rather than null is what says this server holds the
      # file; a null would have checked nothing at all.
      |> where([a], a.remote_url == "" and not is_nil(a.file_file_name))
      |> order_by([a], desc: a.id)
      |> limit(200)
      |> Repo.all()

    missing =
      sample
      |> Enum.reject(&(&1 |> Storage.key_for(:original) |> Storage.exists?()))
      |> Enum.map(&%{id: &1.id, was: &1.file_file_name, now: nil})

    [%{name: "media files", checked: length(sample), failures: missing}]
  end

  ## Copying

  defp copy_trees(source, opts) do
    destination = if Storage.adapter() == Local, do: Local.root()

    if is_binary(destination) do
      Enum.reduce_while(@trees, :ok, &copy_one(&1, &2, source, destination, opts))
    else
      # A bucket rather than a disk. The files are not this step's to move, and
      # saying so is better than silently doing nothing.
      {:error, :not_a_local_store}
    end
  end

  defp copy_one(tree, :ok, source, destination, opts) do
    case copy_tree(Path.join(source, tree), Path.join(destination, tree), opts) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {tree, reason}}}
    end
  end

  defp copy_tree(source, destination, opts) do
    if File.dir?(source) do
      source
      |> walk()
      |> Enum.reduce_while(:ok, fn relative, :ok ->
        continue(copy_file(Path.join(source, relative), Path.join(destination, relative), opts))
      end)
    else
      :ok
    end
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue(error), do: {:halt, error}

  # Depth-first, skipping the cached copies of other servers' files. `cache/`
  # sits at the root of the media directory rather than inside each tree, so
  # this also refuses to follow one that appears lower down.
  defp walk(root, prefix \\ "") do
    case File.ls(Path.join(root, prefix)) do
      {:ok, entries} -> Enum.flat_map(entries, &entries_under(root, prefix, &1))
      {:error, _unreadable} -> []
    end
  end

  defp entries_under(_root, _prefix, "cache"), do: []

  defp entries_under(root, prefix, entry) do
    relative = Path.join(prefix, entry)

    if File.dir?(Path.join(root, relative)), do: walk(root, relative), else: [relative]
  end

  defp copy_file(source, destination, opts) do
    if copied?(source, destination) do
      :ok
    else
      with :ok <- File.mkdir_p(Path.dirname(destination)),
           {:ok, _bytes} <- copy(source, destination, opts) do
        :ok
      end
    end
  end

  defp copy(source, destination, opts) do
    case Keyword.get(opts, :copier) do
      nil -> File.copy(source, destination)
      copier -> copier.(source, destination)
    end
  end

  # Same size is the same file, because nothing is writing to the source during
  # a takeover and a partial copy is shorter than what it was copying.
  defp copied?(source, destination) do
    case {File.stat(source), File.stat(destination)} do
      {{:ok, %{size: size}}, {:ok, %{size: size}}} -> true
      _different_or_missing -> false
    end
  end

  defp root(opts) do
    case Keyword.get(opts, :media_root) do
      root when is_binary(root) and root != "" -> root
      _none -> nil
    end
  end
end
