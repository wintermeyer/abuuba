defmodule Abuuba.Media.Storage do
  @moduledoc """
  Where uploaded files live, and what they are called.

  ## The layout is the reference implementation's, deliberately

      media_attachments/files/003/815/271/original/8f3c2a1b4d5e6f70.jpg

  Class, attachment, the id split into three-digit groups, the style, the
  filename. Not because it is the best possible layout, but because a server
  moving to abuuba can copy its media tree across byte for byte and have every
  path still resolve. A layout of our own would make the importer rewrite
  millions of paths, and every one it got wrong would be a picture nobody can
  see any more.

  Remote media sits under `cache/`. One prefix is what makes a whole tree of
  other people's files safe to delete: it is a copy of something that still
  exists elsewhere, where a local file has nowhere to be fetched back from.

  ## The name is ours, never the uploader's

  A filename arrives from a stranger. Keeping it hands them a say in the URL,
  and two people uploading `holiday.jpg` would collide. The stored name is
  random and only the extension survives, bounded and stripped, because the
  extension is what tells a browser what to do with the bytes.

  ## Two adapters behind one behaviour

  Local disk and S3. The rest of the application asks for a key and a URL and
  does not know which is in force, which is what lets a server move from one to
  the other without touching anything but configuration.
  """

  alias Abuuba.Media.Attachment
  alias Abuuba.Media.Storage.Local

  @doc "Writes a file at a key. `:ok`, or an error nobody should ignore."
  @callback put(key :: String.t(), source_path :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "Removes a file. Missing is not an error."
  @callback delete(key :: String.t()) :: :ok

  @doc "Whether something is stored at a key."
  @callback exists?(key :: String.t()) :: boolean()

  @doc "Where a client fetches it from."
  @callback url(key :: String.t()) :: String.t()

  @doc "A local path for a key, or `nil` where the backend has none."
  @callback local_path(key :: String.t()) :: String.t() | nil

  # Mastodon's, and the reason is above.
  @class "media_attachments"
  @attachment "files"

  # Long enough that guessing one is hopeless, short enough to read out.
  @name_bytes 16

  @doc """
  Which backend is in force.
  """
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:abuuba, :media_storage, Local)

  @doc """
  The key a file is stored under.

  Pass `remote: true` for a copy of somebody else's file.
  """
  @spec key(integer() | String.t(), String.t(), String.t(), keyword()) :: String.t()
  def key(id, style, filename, opts \\ []) do
    prefix = if Keyword.get(opts, :remote, false), do: "cache/", else: ""

    "#{prefix}#{@class}/#{@attachment}/#{partition(id)}/#{style}/#{filename}"
  end

  @doc """
  The id split into three-digit groups, padded to at least nine digits.

  Padding is what keeps the tree shallow and even: without it the first
  thousand attachments would all sit in one directory and everything after
  them in another shape entirely.
  """
  @spec partition(integer() | String.t()) :: String.t()
  def partition(id) do
    digits = id |> to_string() |> String.pad_leading(9, "0")

    digits
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join("/", &Enum.join/1)
  end

  @doc """
  A random name, keeping only a usable extension from what was uploaded.
  """
  @spec filename(String.t() | nil) :: String.t()
  def filename(original) do
    Base.encode16(:crypto.strong_rand_bytes(@name_bytes), case: :lower) <> extension(original)
  end

  @doc """
  Whether an attachment is a copy of somebody else's file.
  """
  @spec remote?(Attachment.t()) :: boolean()
  def remote?(%Attachment{remote_url: url}), do: is_binary(url) and url != ""
  def remote?(_attachment), do: false

  @doc """
  The key one attachment's file or thumbnail is stored under, or `nil`.
  """
  @spec key_for(Attachment.t(), :original | :small) :: String.t() | nil
  def key_for(%Attachment{file_file_name: nil}, :original), do: nil
  def key_for(%Attachment{thumbnail_file_name: nil}, :small), do: nil

  def key_for(%Attachment{} = attachment, style) do
    name =
      case style do
        :original -> attachment.file_file_name
        :small -> attachment.thumbnail_file_name
      end

    key(attachment.id, to_string(style), name, remote: remote?(attachment))
  end

  ## Delegating

  @doc "Writes a file at a key."
  @spec put(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def put(key, source_path, opts \\ []), do: adapter().put(key, source_path, opts)

  @doc "Removes a file."
  @spec delete(String.t() | nil) :: :ok
  def delete(nil), do: :ok
  def delete(key), do: adapter().delete(key)

  @doc "Whether something is stored at a key."
  @spec exists?(String.t() | nil) :: boolean()
  def exists?(nil), do: false
  def exists?(key), do: adapter().exists?(key)

  @doc "Where a client fetches a key from."
  @spec url(String.t() | nil) :: String.t() | nil
  def url(nil), do: nil
  def url(key), do: adapter().url(key)

  @doc """
  A key as the path of a URL.

  Each segment encoded on its own, so the slashes that separate them survive
  and everything else that needs escaping is escaped. Keys this server
  generates are hex and an extension and need none of it, but the importer
  copies the tree of an existing Mastodon instance and those names are
  somebody else's: a key with a space in it is not a URL, and against a bucket
  it is not a signature either.
  """
  @spec encode_key(String.t()) :: String.t()
  def encode_key(key) do
    Enum.map_join(
      String.split(key, "/"),
      "/",
      &URI.encode(&1, fn char ->
        URI.char_unreserved?(char)
      end)
    )
  end

  @doc """
  A local path for a key, where the backend has one.

  `nil` from a backend that does not, which is what the pipeline checks before
  reaching for a file with a local tool.
  """
  @spec local_path(String.t() | nil) :: String.t() | nil
  def local_path(nil), do: nil
  def local_path(key), do: adapter().local_path(key)

  @doc """
  The host clients are sent to, where one is configured.

  A CDN in front is one setting rather than a rewrite of every URL, and it has
  to reach both adapters: a local-disk server behind a cache is as ordinary as
  an S3 one.
  """
  @spec alias_host() :: String.t() | nil
  def alias_host do
    case Application.get_env(:abuuba, :media_alias_host) do
      host when is_binary(host) and host != "" -> String.trim_trailing(host, "/")
      _ -> nil
    end
  end

  # Bounded, lowercased and stripped of anything that is not a letter or a
  # digit, so an "extension" cannot become a path of its own.
  defp extension(nil), do: ""

  defp extension(original) do
    original
    |> to_string()
    |> Path.extname()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9.]/, "")
    |> String.trim_leading(".")
    |> String.slice(0, 8)
    |> case do
      "" -> ""
      extension -> "." <> extension
    end
  end
end
