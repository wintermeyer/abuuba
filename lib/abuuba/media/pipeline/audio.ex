defmodule Abuuba.Media.Pipeline.Audio do
  @moduledoc """
  Audio, and the picture that comes with it.

  Everything becomes mp3, which is the format every browser plays without
  asking. A player also needs something to look at, so cover art embedded in
  the file is pulled out as the thumbnail, and its average colour becomes the
  accent the player draws itself in. A grey rectangle with a waveform is what
  a player looks like when nobody bothered.
  """

  alias Abuuba.Media.Blurhash
  alias Abuuba.Media.FFmpeg
  alias Vix.Vips.Image, as: Vips
  alias Vix.Vips.Operation

  @doc """
  Processes an audio file in place, returning what the attachment should
  record.
  """
  @spec process(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def process(path, thumbnail_path) do
    with {:ok, probe} <- FFmpeg.probe(path),
         audio when not is_nil(audio) <- FFmpeg.stream(probe, "audio"),
         # Before the transcode, not after: the transcode drops every stream
         # that is not audio, and the cover is a video stream.
         cover = extract_cover(probe, path, thumbnail_path),
         :ok <- transcode(path) do
      {:ok,
       %{
         duration: FFmpeg.duration(probe),
         cover?: cover != nil,
         accent_colour: cover
       }}
    else
      nil -> {:error, :no_audio_stream}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Inside

  defp transcode(path) do
    output = path <> ".out.mp3"

    args = ["-y", "-i", path, "-vn", "-c:a", "libmp3lame", "-b:a", "192k", output]

    with {:ok, _} <- FFmpeg.run(args) do
      File.rename(output, path)
    end
  end

  # A video stream inside an audio file is the cover art; there is nothing else
  # it could be.
  defp extract_cover(probe, path, thumbnail_path) do
    case FFmpeg.stream(probe, "video") do
      nil ->
        nil

      _stream ->
        args = ["-y", "-i", path, "-an", "-frames:v", "1", thumbnail_path]

        case FFmpeg.run(args) do
          {:ok, _} -> accent_colour(thumbnail_path)
          _ -> nil
        end
    end
  end

  # The average colour of the cover, taken the way a blurhash takes one, so the
  # player's accent and the placeholder agree with each other.
  defp accent_colour(thumbnail_path) do
    with {:ok, image} <- Vips.new_from_file(thumbnail_path),
         {:ok, small} <- Operation.resize(image, 8 / max(Vips.width(image), 1)),
         {:ok, pixels} <- Vips.write_to_binary(small) do
      pixels
      |> rgb_only(Vips.bands(small))
      |> Blurhash.encode(Vips.width(small), Vips.height(small))
      |> Blurhash.average_colour()
    else
      _ -> nil
    end
  end

  defp rgb_only(pixels, 3), do: pixels

  defp rgb_only(pixels, 4) do
    for <<r, g, b, _a <- pixels>>, into: <<>>, do: <<r, g, b>>
  end

  defp rgb_only(pixels, _bands), do: pixels
end
