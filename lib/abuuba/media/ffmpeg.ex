defmodule Abuuba.Media.FFmpeg do
  @moduledoc """
  Running ffmpeg and reading what ffprobe says.

  One module rather than `System.cmd` at each call site, because the arguments
  that matter are easy to leave out: `-nostdin` (or a malformed file makes the
  worker wait forever for input nobody will type), a timeout, and reading
  stderr so a failure says what went wrong instead of "it did not work".

  Everything here treats the file as something a stranger wrote. A container
  can claim anything, so what a stream actually is comes from ffprobe rather
  than from the extension or the upload's content type.
  """

  require Logger

  # Long enough for a real transcode of a long video, short enough that a file
  # crafted to make ffmpeg spin does not hold a queue slot all day.
  @timeout :timer.minutes(10)

  @doc """
  What is inside a file: streams, duration, and the container's own guess.

  `{:error, reason}` where the file cannot be read at all, which is the honest
  answer for a container that is not one.
  """
  @spec probe(String.t()) :: {:ok, map()} | {:error, term()}
  def probe(path) do
    args = [
      "-v",
      "error",
      "-print_format",
      "json",
      "-show_format",
      "-show_streams",
      path
    ]

    case run("ffprobe", args) do
      {:ok, output} -> decode(output)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs ffmpeg with the given arguments.
  """
  @spec run(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def run(command \\ "ffmpeg", args) do
    # `-nostdin` for ffmpeg only: without it a malformed file makes it wait
    # forever for input nobody will type. ffprobe has no such flag and exits
    # with an error if it is passed one, which is the sort of thing that looks
    # like a broken file for an afternoon.
    args = if command == "ffmpeg", do: ["-nostdin" | args], else: args

    task = Task.async(fn -> System.cmd(command, args, stderr_to_stdout: true) end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, status}} ->
        Logger.warning("#{command} exited #{status}: #{String.slice(output, 0, 500)}")

        {:error, {:exit, status}}

      nil ->
        {:error, :timeout}
    end
  end

  @doc """
  Whether ffmpeg is on this machine at all.

  Asked rather than assumed, so a server without it records a failed
  attachment with a reason instead of crashing a worker on every upload.
  """
  @spec available?() :: boolean()
  def available?,
    do: System.find_executable("ffmpeg") != nil and System.find_executable("ffprobe") != nil

  @doc """
  The first stream of a kind, or `nil`.
  """
  @spec stream(map(), String.t()) :: map() | nil
  def stream(%{"streams" => streams}, kind) do
    Enum.find(streams, &(&1["codec_type"] == kind))
  end

  def stream(_probe, _kind), do: nil

  @doc """
  How long the file runs, in seconds, or `nil` where nothing says.
  """
  @spec duration(map()) :: float() | nil
  def duration(%{"format" => %{"duration" => duration}}) when is_binary(duration) do
    case Float.parse(duration) do
      {seconds, _rest} -> seconds
      :error -> nil
    end
  end

  def duration(_probe), do: nil

  defp decode(output) do
    case Jason.decode(output) do
      {:ok, %{} = probe} -> {:ok, probe}
      _ -> {:error, :unreadable}
    end
  end
end
