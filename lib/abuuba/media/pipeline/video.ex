defmodule Abuuba.Media.Pipeline.Video do
  @moduledoc """
  Video, and the trick that makes most of it free.

  ## Passthrough when the file is already what we would have made

  A phone records h264 video and aac audio in an mp4 container, which is
  exactly what a transcode would produce. Re-encoding it costs minutes of CPU
  and loses quality to make a file that is no more playable than the one that
  arrived. So when the streams are already compliant, the file is remuxed with
  `-c copy`: the same bytes, moved into a container with its index at the
  front. That is seconds of work instead of minutes, and it is the single
  biggest saving in the whole pipeline.

  ## Faststart either way

  The index goes at the front so a browser can start playing before the file
  has finished downloading. Without it a reader watches a spinner for the
  length of the download, which on a phone is the difference between a video
  somebody watches and one they scroll past.

  ## An animated GIF becomes a video

  A looping GIF is an enormous file for what it shows. Converted to mp4 and
  marked `gifv`, it plays the same and costs a tenth as much, which is what the
  reference implementation does and what clients expect to receive.
  """

  alias Abuuba.Media.FFmpeg

  # What a browser plays without asking anybody to install anything.
  @video_codec "h264"
  @audio_codec "aac"

  # Enough for a phone recording, not enough to hand somebody a 4K film as a
  # timeline attachment.
  @max_width 1920
  @max_height 1080
  @max_frame_rate 60

  # Bits per pixel per second, which is what a bitrate actually is. Multiplying
  # it out beats a fixed number, because 720p and 1080p at the same bitrate are
  # two very different pictures.
  @bits_per_pixel 0.08

  @doc """
  Processes a video in place, returning what the attachment should record.
  """
  @spec process(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def process(path, thumbnail_path, opts \\ []) do
    with {:ok, probe} <- FFmpeg.probe(path),
         video when not is_nil(video) <- FFmpeg.stream(probe, "video"),
         {:ok, meta} <- convert(path, probe, video, opts),
         :ok <- thumbnail(path, thumbnail_path) do
      {:ok, meta}
    else
      nil -> {:error, :no_video_stream}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whether this file can be moved into place without being re-encoded.

  The one question worth asking before spending minutes of CPU.
  """
  @spec passthrough?(map()) :: boolean()
  def passthrough?(probe) do
    video = FFmpeg.stream(probe, "video")
    audio = FFmpeg.stream(probe, "audio")

    video != nil and video["codec_name"] == @video_codec and
      within_limits?(video) and
      (audio == nil or audio["codec_name"] == @audio_codec)
  end

  @doc """
  Turns an animated picture into a video.
  """
  @spec to_gifv(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def to_gifv(path, output) do
    args = [
      "-y",
      "-i",
      path,
      "-movflags",
      "+faststart",
      # An mp4 whose dimensions are odd cannot be encoded at all by h264, and a
      # GIF is under no obligation to be even.
      "-vf",
      "scale=trunc(iw/2)*2:trunc(ih/2)*2",
      "-pix_fmt",
      "yuv420p",
      "-c:v",
      "libx264",
      "-preset",
      "veryfast",
      "-an",
      output
    ]

    with {:ok, _output} <- FFmpeg.run(args),
         {:ok, probe} <- FFmpeg.probe(output),
         video when not is_nil(video) <- FFmpeg.stream(probe, "video") do
      {:ok, dimensions(video, probe)}
    else
      nil -> {:error, :no_video_stream}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Writes the first frame of a video as a picture.
  """
  @spec thumbnail(String.t(), String.t()) :: :ok | {:error, term()}
  def thumbnail(path, output) do
    args = ["-y", "-i", path, "-frames:v", "1", "-vf", "scale=640:-2", output]

    case FFmpeg.run(args) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  ## Inside

  defp convert(path, probe, video, opts) do
    if Keyword.get(opts, :force_transcode, false) or not passthrough?(probe) do
      transcode(path, probe, video)
    else
      remux(path, probe, video)
    end
  end

  defp remux(path, probe, video) do
    output = path <> ".remux.mp4"

    args = ["-y", "-i", path, "-c", "copy", "-movflags", "+faststart", output]

    with {:ok, _} <- FFmpeg.run(args),
         :ok <- File.rename(output, path) do
      {:ok, Map.put(dimensions(video, probe), :passthrough, true)}
    end
  end

  defp transcode(path, _probe, video) do
    output = path <> ".out.mp4"

    with {:ok, _} <- FFmpeg.run(transcode_args(path, video, output)),
         :ok <- File.rename(output, path),
         {:ok, after_probe} <- FFmpeg.probe(path),
         encoded when not is_nil(encoded) <- FFmpeg.stream(after_probe, "video") do
      {:ok, Map.put(dimensions(encoded, after_probe), :passthrough, false)}
    else
      nil -> {:error, :no_video_stream}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transcode_args(path, video, output) do
    [
      "-y",
      "-i",
      path,
      "-vf",
      "scale='min(#{@max_width},iw)':'min(#{@max_height},ih)':force_original_aspect_ratio=decrease:force_divisible_by=2",
      "-r",
      to_string(min(frame_rate(video), @max_frame_rate)),
      "-c:v",
      "libx264",
      "-preset",
      "veryfast",
      "-pix_fmt",
      "yuv420p",
      "-b:v",
      "#{bitrate(video)}k",
      "-c:a",
      "aac",
      "-b:a",
      "128k",
      "-movflags",
      "+faststart",
      output
    ]
  end

  # A bitrate that follows the picture rather than a number somebody picked.
  defp bitrate(video) do
    width = min(video["width"] || @max_width, @max_width)
    height = min(video["height"] || @max_height, @max_height)
    rate = min(frame_rate(video), @max_frame_rate)

    (width * height * rate * @bits_per_pixel / 1000) |> round() |> max(256) |> min(6_000)
  end

  defp frame_rate(video) do
    case String.split(to_string(video["avg_frame_rate"] || video["r_frame_rate"]), "/") do
      [numerator, denominator] ->
        with {top, ""} <- Integer.parse(numerator),
             {bottom, ""} <- Integer.parse(denominator),
             true <- bottom > 0 do
          round(top / bottom)
        else
          _ -> 30
        end

      _ ->
        30
    end
  end

  defp within_limits?(video) do
    (video["width"] || 0) <= @max_width and (video["height"] || 0) <= @max_height and
      frame_rate(video) <= @max_frame_rate
  end

  defp dimensions(video, probe) do
    %{
      width: video["width"],
      height: video["height"],
      frame_rate: frame_rate(video),
      duration: FFmpeg.duration(probe)
    }
  end
end
