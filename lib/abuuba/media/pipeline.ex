defmodule Abuuba.Media.Pipeline do
  @moduledoc """
  What happens to an upload after it has been stored.

  One entry point, dispatching by what the file actually is. Each kind's work
  lives in its own module; what is here is the ordering and the honest failure:
  a file that cannot be processed is recorded as failed with a reason, because
  a client polling a 206 that never becomes a 200 is waiting for something that
  is never coming.

  ## Nothing here trusts the upload's own description

  A container can claim anything. What a file is comes from reading it, so a
  video labelled as a picture is processed as a video or refused, never opened
  by the wrong tool because a header said so.
  """

  alias Abuuba.Media
  alias Abuuba.Media.Attachment
  alias Abuuba.Media.FFmpeg
  alias Abuuba.Media.Pipeline.Audio
  alias Abuuba.Media.Pipeline.Image
  alias Abuuba.Media.Pipeline.Video
  alias Abuuba.Media.Storage
  alias Abuuba.Media.Upload

  @doc """
  Processes one attachment, updating the row as it goes.
  """
  @spec run(Attachment.t()) :: {:ok, Attachment.t()} | {:error, term()}
  def run(%Attachment{} = attachment) do
    key = Storage.key_for(attachment, :original)

    case working_copy(key) do
      {:ok, path, in_place?} -> process(attachment, key, path, in_place?)
      :error -> fail(attachment, :missing_file)
    end
  end

  # On local disk the file is processed where it lies, which for a 99 MB video
  # is a copy nobody has to make. On a backend with no local path it is fetched
  # to a temporary file and written back, which is the same pipeline either
  # way rather than two of them.
  defp working_copy(nil), do: :error

  defp working_copy(key) do
    case Storage.local_path(key) do
      path when is_binary(path) ->
        if File.exists?(path), do: {:ok, path, true}, else: :error

      nil ->
        fetch_to_temp(key)
    end
  end

  defp fetch_to_temp(key) do
    path = Path.join(System.tmp_dir!(), "abuuba-work-#{Path.basename(key)}")

    case Req.get(Storage.url(key), into: File.stream!(path), retry: false) do
      {:ok, %{status: 200}} -> {:ok, path, false}
      _ -> :error
    end
  end

  defp process(attachment, key, path, in_place?) do
    thumbnail = Upload.thumbnail_path_for(attachment)

    case dispatch(attachment, path, thumbnail) do
      {:ok, meta} -> complete(attachment, meta, key, path, thumbnail, in_place?)
      {:error, reason} -> fail(attachment, reason)
    end
  end

  defp dispatch(%Attachment{type: :image} = attachment, path, thumbnail) do
    if animated?(attachment, path) do
      to_gifv(path, thumbnail)
    else
      Image.process(path, thumbnail, attachment.file_content_type)
    end
  end

  defp dispatch(%Attachment{type: type}, path, thumbnail) when type in [:video, :gifv] do
    with :ok <- require_ffmpeg(), do: Video.process(path, thumbnail)
  end

  defp dispatch(%Attachment{type: :audio}, path, thumbnail) do
    with :ok <- require_ffmpeg(), do: Audio.process(path, thumbnail)
  end

  defp dispatch(_attachment, _path, _thumbnail), do: {:error, :unsupported_type}

  # An animated GIF is an enormous file for what it shows, and every client
  # already knows how to play a `gifv`.
  defp animated?(%Attachment{file_content_type: "image/gif"}, path) do
    if FFmpeg.available?() do
      case FFmpeg.probe(path) do
        {:ok, probe} -> frames(probe) > 1
        _ -> false
      end
    else
      false
    end
  end

  defp animated?(_attachment, _path), do: false

  defp frames(probe) do
    case FFmpeg.stream(probe, "video") do
      %{"nb_frames" => frames} when is_binary(frames) ->
        case Integer.parse(frames) do
          {number, _rest} -> number
          _ -> 1
        end

      _ ->
        1
    end
  end

  defp to_gifv(path, thumbnail) do
    output = path <> ".gifv.mp4"

    with {:ok, meta} <- Video.to_gifv(path, output),
         :ok <- File.rename(output, path),
         :ok <- Video.thumbnail(path, thumbnail) do
      {:ok, Map.merge(meta, %{type: :gifv, content_type: "video/mp4"})}
    end
  end

  defp require_ffmpeg do
    if FFmpeg.available?(), do: :ok, else: {:error, :ffmpeg_missing}
  end

  defp complete(attachment, meta, key, path, thumbnail_path, in_place?) do
    unless in_place? do
      Storage.put(key, path)
      File.rm(path)
    end

    Media.finish_processing(attachment, %{
      meta: meta_for(attachment, meta),
      blurhash: Map.get(meta, :blurhash) || attachment.blurhash,
      type: Map.get(meta, :type, attachment.type),
      file_content_type: Map.get(meta, :content_type, attachment.file_content_type),
      thumbnail: store_thumbnail(attachment, thumbnail_path)
    })
  end

  # Written by a local tool to a working path, then handed to whichever backend
  # is in force under a name of its own. The name is random for the same reason
  # the original's is: nothing a stranger wrote reaches a path.
  defp store_thumbnail(attachment, path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 ->
        name = Storage.filename(path)
        key = Storage.key(attachment.id, "small", name, remote: Storage.remote?(attachment))

        case Storage.put(key, path) do
          :ok ->
            File.rm(path)

            %{name: name, size: size, content_type: MIME.from_path(path)}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp meta_for(attachment, meta) do
    original =
      %{
        "width" => meta[:width],
        "height" => meta[:height],
        "duration" => meta[:duration],
        "frame_rate" => meta[:frame_rate]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> put_aspect()

    attachment.meta
    |> Map.put("original", Map.merge(Map.get(attachment.meta, "original", %{}), original))
    |> maybe_put("small", small_meta(meta))
    |> maybe_put("accent_colour", meta[:accent_colour])
    |> maybe_put("passthrough", meta[:passthrough])
  end

  defp small_meta(%{thumbnail_width: width, thumbnail_height: height})
       when is_integer(width) and is_integer(height) do
    put_aspect(%{"width" => width, "height" => height})
  end

  defp small_meta(_meta), do: nil

  # Clients lay a timeline out before the picture has loaded, and the ratio is
  # what stops the page jumping when it does.
  defp put_aspect(%{"width" => width, "height" => height} = meta)
       when is_integer(width) and is_integer(height) and height > 0 do
    meta
    |> Map.put("size", "#{width}x#{height}")
    |> Map.put("aspect", width / height)
  end

  defp put_aspect(meta), do: meta

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fail(attachment, reason) do
    {:ok, _} = Media.set_processing(attachment, :failed, describe(reason))

    {:error, reason}
  end

  defp describe(reason) when is_atom(reason) or is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
