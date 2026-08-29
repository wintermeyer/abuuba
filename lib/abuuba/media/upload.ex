defmodule Abuuba.Media.Upload do
  @moduledoc """
  Taking a file off a request and putting it somewhere it can be served from.

  Local disk, under a directory from config. Storage backends are their own
  issue and so is the processing pipeline; what is here is the least that lets
  the upload endpoints answer honestly, and it is behind one function so that
  swapping it for S3 later is a change in one place.

  ## Why the path is derived from the id

  Not from the name somebody uploaded. A filename arrives from a stranger and
  can contain `..`, a null byte, or a name that collides with somebody else's,
  and every one of those is a way to write outside the directory or over
  another person's file. The id is ours and is unique by construction; the
  original name is kept as metadata for the download header and never used to
  build a path.
  """

  alias Abuuba.Media.Attachment
  alias Abuuba.Media.Storage

  # What a browser will render inline and what an image endpoint should accept.
  # An allow list rather than a deny list: the set of things that are safe to
  # serve is small and known, and the set of things that are not grows with
  # every format anybody invents.
  @image_types ~w(image/jpeg image/png image/gif image/webp image/avif)
  @video_types ~w(video/mp4 video/webm video/quicktime)
  @audio_types ~w(audio/mpeg audio/ogg audio/wav audio/flac audio/mp4)

  # Small enough to process in the request without anybody noticing, which is
  # what makes an ordinary photo post feel instant.
  @synchronous_bytes 2 * 1024 * 1024

  # Per kind rather than one number for everything. A picture that big is a
  # mistake; a video that small is a five-second clip. These are the reference
  # implementation's, and the instance document reports the same ones, so a
  # client that checks before uploading and the server that refuses afterwards
  # cannot disagree.
  @max_image_bytes 16 * 1024 * 1024
  @max_video_bytes 99 * 1024 * 1024

  @doc """
  Where uploads are written on this machine.

  Only meaningful for the local backend; see `Abuuba.Media.Storage`.
  """
  @spec root() :: String.t()
  defdelegate root(), to: Abuuba.Media.Storage.Local

  @doc """
  Stores a file and returns what the attachment should record about it.
  """
  @spec store(map(), integer()) :: {:ok, map()} | {:error, atom()}
  def store(%{path: path, filename: filename} = upload, id) do
    content_type = content_type(upload)

    name = Storage.filename(named_extension(filename, content_type))

    with :ok <- check_type(content_type),
         {:ok, %{size: size}} <- File.stat(path),
         :ok <- check_size(size, kind(content_type)),
         :ok <- Storage.put(Storage.key(id, "original", name), path) do
      {:ok,
       %{
         file_file_name: name,
         file_content_type: content_type,
         file_file_size: size,
         type: kind(content_type),
         meta: %{"original" => %{"size" => size, "name" => filename}}
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _reason} -> {:error, :storage}
    end
  end

  def store(_upload, _id), do: {:error, :unsupported}

  @doc """
  Stores a picture to stand in for a video or an audio file.

  Only a picture: handed a video, the thumbnail would be served where a browser
  expects an image and would render as nothing. Written under a name of its own
  so that replacing one does not touch the file it stands for.
  """
  @spec store_thumbnail(map(), integer()) :: {:ok, map()} | {:error, atom()}
  def store_thumbnail(%{path: path, filename: filename} = upload, id) do
    content_type = content_type(upload)

    name = Storage.filename(named_extension(filename, content_type))

    with :ok <- check_image(content_type),
         {:ok, %{size: size}} <- File.stat(path),
         :ok <- Storage.put(Storage.key(id, "small", name), path) do
      {:ok,
       %{
         thumbnail_file_name: name,
         thumbnail_content_type: content_type,
         thumbnail_file_size: size
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _reason} -> {:error, :storage}
    end
  end

  def store_thumbnail(_upload, _id), do: {:error, :unsupported}

  @doc """
  The URL a client fetches a stored thumbnail from.
  """
  @spec thumbnail_url(Attachment.t()) :: String.t() | nil
  def thumbnail_url(%Attachment{} = attachment) do
    attachment |> Storage.key_for(:small) |> Storage.url()
  end

  # What the stored name ends in, decided by the content type and never by the
  # uploaded name.
  #
  # The name is a stranger's to write and nothing has checked it; the type has
  # been through `check_type/1`. Taking the name's extension meant that a file
  # called `payload.html`, uploaded as `image/png`, was stored as `.html` and
  # served back as `text/html` from this server's own origin — which is where
  # the session cookie lives. There is no header that fixes that, because at
  # that point the file really is being served as a page.
  #
  # A browser handed a file with no extension has to guess what to do with it,
  # and the type is a better answer than the name anyway.
  defp named_extension(_filename, content_type) do
    "upload" <> default_extension(content_type)
  end

  # Per kind, and the same numbers the instance document reports, so a client
  # that checks before uploading and a server that refuses afterwards cannot
  # disagree about what the limit was.
  defp check_size(size, kind) do
    if size <= max_bytes(kind), do: :ok, else: {:error, :too_large}
  end

  @doc """
  Whether a file is small enough to finish inside the request.

  An ordinary photo is, and making somebody poll for it would turn a post into
  two round trips for no reason. Anything larger is queued, which is what the
  202 in the v2 endpoint is telling the client.
  """
  @spec synchronous?(map()) :: boolean()
  def synchronous?(%{path: path} = upload) do
    case File.stat(path) do
      {:ok, %{size: size}} -> kind(content_type(upload)) == :image and size <= @synchronous_bytes
      _ -> false
    end
  end

  def synchronous?(_upload), do: false

  @doc """
  The largest file finished inside a request.
  """
  @spec synchronous_bytes() :: pos_integer()
  def synchronous_bytes, do: @synchronous_bytes

  @doc """
  The URL a client fetches a stored file from.
  """
  @spec url(Attachment.t()) :: String.t() | nil
  def url(%Attachment{} = attachment) do
    attachment |> Storage.key_for(:original) |> Storage.url()
  end

  @doc """
  Where an attachment's file sits on disk, or `nil` before one is stored.
  """
  @spec path_of(Attachment.t()) :: String.t() | nil
  def path_of(%Attachment{file_file_name: nil}), do: nil
  def path_of(%Attachment{file_file_name: name}), do: Path.join(root(), name)

  @doc """
  Where an attachment's thumbnail should be written.

  Derived from the id like everything else here, so that nothing a stranger
  named reaches a path. The extension follows what the thumbnail will be, since
  the file is written before the row knows about it.
  """
  @spec thumbnail_path_for(Attachment.t(), String.t()) :: String.t()
  def thumbnail_path_for(%Attachment{} = attachment, extension \\ nil) do
    extension = extension || thumbnail_extension(attachment)

    Path.join(root(), "#{attachment.id}-small#{extension}")
  end

  # A thumbnail of a picture keeps that picture's format where a browser can
  # render it; everything else gets a JPEG, which everything can.
  defp thumbnail_extension(%Attachment{type: :image, file_content_type: "image/png"}), do: ".png"

  defp thumbnail_extension(%Attachment{type: :image, file_content_type: "image/webp"}),
    do: ".webp"

  defp thumbnail_extension(_attachment), do: ".jpg"

  @doc """
  Removes the files an attachment stored, if any.

  Missing files are not an error: the sweeper and a person changing their mind
  can both arrive here, and one having already run is the ordinary case rather
  than a fault.
  """
  @spec discard(Attachment.t()) :: :ok
  def discard(%Attachment{} = attachment) do
    [attachment.file_file_name, attachment.thumbnail_file_name]
    |> Enum.reject(&is_nil/1)
    |> Enum.each(&File.rm(Path.join(root(), &1)))
  end

  @doc """
  Which broad kind a content type is.
  """
  @spec kind(String.t() | nil) :: atom()
  def kind(type) when type in @image_types, do: :image
  def kind(type) when type in @video_types, do: :video
  def kind(type) when type in @audio_types, do: :audio
  def kind(_type), do: :unknown

  @doc """
  Every content type this server accepts.
  """
  @spec accepted_types() :: [String.t()]
  def accepted_types, do: @image_types ++ @video_types ++ @audio_types

  @doc """
  The same set as file extensions, which is what a file picker filters on.

  Derived from the types rather than written out again: two lists of the same
  thing drift, and the one that drifts is always the one a person sees.
  """
  @spec accepted_extensions() :: [String.t()]
  def accepted_extensions do
    accepted_types()
    |> Enum.map(&default_extension/1)
    |> Enum.reject(&(&1 == ".bin"))
    |> Enum.concat([".jpeg"])
    |> Enum.uniq()
  end

  @doc """
  The largest file this server takes.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: max(max_bytes(:image), max_bytes(:video))

  @doc """
  The largest file of one kind, from settings where an admin has changed it.
  """
  @spec max_bytes(atom()) :: pos_integer()
  def max_bytes(:image), do: configured("media_image_size_limit", @max_image_bytes)

  def max_bytes(kind) when kind in [:video, :audio],
    do: configured("media_video_size_limit", @max_video_bytes)

  def max_bytes(_kind), do: configured("media_image_size_limit", @max_image_bytes)

  defp configured(key, default) do
    case Abuuba.Settings.get(key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp check_type(type) do
    if type in accepted_types(), do: :ok, else: {:error, :unsupported}
  end

  defp check_image(type) do
    if type in @image_types, do: :ok, else: {:error, :unsupported}
  end

  # Built from the id, never from what was uploaded. A filename from a stranger
  # can carry `..`, a null byte, or somebody else's name.
  defp default_extension("image/jpeg"), do: ".jpg"
  defp default_extension("image/png"), do: ".png"
  defp default_extension("image/gif"), do: ".gif"
  defp default_extension("image/webp"), do: ".webp"
  defp default_extension("image/avif"), do: ".avif"
  defp default_extension("video/mp4"), do: ".mp4"
  defp default_extension("video/webm"), do: ".webm"
  defp default_extension("video/quicktime"), do: ".mov"
  defp default_extension("audio/mpeg"), do: ".mp3"
  defp default_extension("audio/ogg"), do: ".ogg"
  defp default_extension("audio/wav"), do: ".wav"
  defp default_extension("audio/flac"), do: ".flac"
  defp default_extension("audio/mp4"), do: ".m4a"
  defp default_extension(_type), do: ".bin"

  defp content_type(%{content_type: type}) when is_binary(type) do
    type |> String.split(";") |> List.first() |> String.trim() |> String.downcase()
  end

  defp content_type(_upload), do: ""
end
