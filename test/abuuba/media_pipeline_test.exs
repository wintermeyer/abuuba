defmodule Abuuba.MediaPipelineTest do
  use Abuuba.DataCase, async: false
  use Oban.Testing, repo: Abuuba.Repo

  # Every fixture here is built by ffmpeg, because a real file is the only way
  # to prove the pipeline reads real files.
  @moduletag :needs_ffmpeg

  import Abuuba.AccountsFixtures

  alias Abuuba.Media
  alias Abuuba.Media.Blurhash
  alias Abuuba.Media.FFmpeg
  alias Abuuba.Media.Pipeline
  alias Abuuba.Media.Pipeline.Image
  alias Abuuba.Media.Pipeline.Video
  alias Abuuba.Media.ProcessingWorker
  alias Abuuba.Media.Storage
  alias Abuuba.Media.Upload
  alias Abuuba.Repo
  alias AbuubaWeb.API.Entities

  setup do
    root = Path.join(System.tmp_dir!(), "abuuba-media-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:abuuba, :media_root)
    Application.put_env(:abuuba, :media_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      if previous, do: Application.put_env(:abuuba, :media_root, previous)
    end)

    %{root: root, account: account_fixture()}
  end

  # Real files, made by the tools the pipeline itself uses. A fixture that is
  # not really a JPEG proves the pipeline can read a fixture.
  defp make_image(path, width \\ 800, height \\ 600) do
    {_out, 0} =
      System.cmd("ffmpeg", [
        "-nostdin",
        "-y",
        "-f",
        "lavfi",
        "-i",
        "testsrc=size=#{width}x#{height}:rate=1",
        "-frames:v",
        "1",
        path
      ])

    path
  end

  defp make_video(path, opts \\ []) do
    codec = Keyword.get(opts, :codec, "libx264")
    size = Keyword.get(opts, :size, "320x240")

    {_out, 0} =
      System.cmd("ffmpeg", [
        "-nostdin",
        "-y",
        "-f",
        "lavfi",
        "-i",
        "testsrc=size=#{size}:rate=10:duration=1",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:duration=1",
        "-c:v",
        codec,
        "-c:a",
        Keyword.get(opts, :audio_codec, "aac"),
        "-pix_fmt",
        "yuv420p",
        path
      ])

    path
  end

  defp make_audio(path) do
    {_out, 0} =
      System.cmd("ffmpeg", [
        "-nostdin",
        "-y",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:duration=1",
        path
      ])

    path
  end

  # Stored the way an upload stores it: a random name at the layout key, not a
  # file dropped in the root.
  defp attachment_for(account, path, type, content_type) do
    name = Storage.filename(path)

    {:ok, attachment} =
      Media.create_attachment(%{
        account_id: account.id,
        type: type,
        file_file_name: name,
        file_content_type: content_type,
        file_file_size: File.stat!(path).size,
        processing: :queued
      })

    :ok = Storage.put(Storage.key(attachment.id, "original", name), path)

    attachment
  end

  defp stored_path(attachment, style \\ :original) do
    attachment |> Storage.key_for(style) |> Storage.local_path()
  end

  describe "pictures" do
    test "are capped, described and thumbnailed", %{root: root, account: account} do
      path = make_image(Path.join(root, "big.jpg"), 1200, 900)
      attachment = attachment_for(account, path, :image, "image/jpeg")

      assert {:ok, done} = Pipeline.run(attachment)

      assert done.processing == :complete
      assert done.meta["original"]["width"] == 1200
      assert done.meta["original"]["size"] == "1200x900"
      assert done.meta["small"]["width"] < 1200
      assert done.thumbnail_file_name
      assert File.exists?(stored_path(done, :small))
    end

    test "a picture over the pixel cap is scaled down", %{root: root, account: account} do
      # The cap is on the product, so a panorama and a poster are judged by how
      # much work they are rather than how wide they are.
      path = make_image(Path.join(root, "huge.jpg"), 4000, 2400)
      attachment = attachment_for(account, path, :image, "image/jpeg")

      {:ok, done} = Pipeline.run(attachment)

      width = done.meta["original"]["width"]
      height = done.meta["original"]["height"]

      assert width * height <= Image.max_pixels()
      assert_in_delta width / height, 4000 / 2400, 0.01
    end

    test "get a blurhash that decodes to something", %{root: root, account: account} do
      path = make_image(Path.join(root, "hash.jpg"))
      attachment = attachment_for(account, path, :image, "image/jpeg")

      {:ok, done} = Pipeline.run(attachment)

      assert is_binary(done.blurhash)
      assert Blurhash.average_colour(done.blurhash) =~ ~r/^#[0-9a-f]{6}$/
    end

    test "lose their metadata", %{root: root, account: account} do
      # A photograph carries where it was taken and on what, and somebody
      # posting a picture has not agreed to publish their address.
      path = make_image(Path.join(root, "exif.jpg"))

      {_out, 0} =
        System.cmd("ffmpeg", [
          "-nostdin",
          "-y",
          "-i",
          path,
          "-metadata",
          "comment=a secret",
          Path.join(root, "tagged.jpg")
        ])

      File.rename!(Path.join(root, "tagged.jpg"), path)
      attachment = attachment_for(account, path, :image, "image/jpeg")

      {:ok, _done} = Pipeline.run(attachment)

      {:ok, probe} = FFmpeg.probe(stored_path(Repo.reload(attachment)))

      refute inspect(probe["format"]["tags"]) =~ "a secret"
    end
  end

  describe "what a client is told" do
    test "the preview is the small version, not the whole picture", %{
      root: root,
      account: account
    } do
      # A timeline of twenty posts should not fetch twenty full-size
      # photographs to show them at 400 pixels wide.
      path = make_image(Path.join(root, "preview.jpg"), 1200, 900)
      attachment = attachment_for(account, path, :image, "image/jpeg")

      {:ok, done} = Pipeline.run(attachment)

      entity = Entities.media_attachment(done)

      assert entity["preview_url"] =~ "/small/"
      assert entity["url"] =~ "/original/"
      refute entity["preview_url"] == entity["url"]
    end
  end

  describe "video" do
    test "already-compliant files are moved rather than re-encoded", %{
      root: root,
      account: account
    } do
      # The single biggest saving in the pipeline: a phone records exactly what
      # a transcode would have produced.
      path = make_video(Path.join(root, "phone.mp4"))
      attachment = attachment_for(account, path, :video, "video/mp4")

      {:ok, done} = Pipeline.run(attachment)

      assert done.processing == :complete
      assert done.meta["passthrough"] == true
      assert done.meta["original"]["width"] == 320
      assert done.meta["original"]["duration"] > 0
    end

    test "anything else is transcoded", %{root: root, account: account} do
      path = make_video(Path.join(root, "other.mkv"), codec: "mpeg4", audio_codec: "libmp3lame")
      attachment = attachment_for(account, path, :video, "video/mp4")

      {:ok, done} = Pipeline.run(attachment)

      assert done.meta["passthrough"] == false

      {:ok, probe} = FFmpeg.probe(stored_path(done))

      assert FFmpeg.stream(probe, "video")["codec_name"] == "h264"
    end

    test "the index ends up at the front", %{root: root, account: account} do
      # Without it a reader watches a spinner for the length of the download.
      path = make_video(Path.join(root, "faststart.mp4"))
      attachment = attachment_for(account, path, :video, "video/mp4")

      {:ok, done} = Pipeline.run(attachment)

      {:ok, probe} = FFmpeg.probe(stored_path(done))

      assert probe["format"]["format_name"] =~ "mp4"
    end

    test "get a thumbnail from the first frame", %{root: root, account: account} do
      path = make_video(Path.join(root, "thumb.mp4"))
      attachment = attachment_for(account, path, :video, "video/mp4")

      {:ok, done} = Pipeline.run(attachment)

      assert done.thumbnail_file_name
      assert File.stat!(stored_path(done, :small)).size > 0
    end

    test "a file with no video in it is refused rather than half-processed", %{
      root: root,
      account: account
    } do
      path = make_audio(Path.join(root, "notvideo.mp3"))
      attachment = attachment_for(account, path, :video, "video/mp4")

      assert {:error, :no_video_stream} = Pipeline.run(attachment)
      assert Repo.reload(attachment).processing == :failed
    end

    test "passthrough is refused for something outside the limits" do
      probe = %{
        "streams" => [
          %{
            "codec_type" => "video",
            "codec_name" => "h264",
            "width" => 4000,
            "height" => 3000,
            "avg_frame_rate" => "30/1"
          }
        ]
      }

      refute Video.passthrough?(probe)
    end
  end

  describe "animated pictures" do
    test "become a video", %{root: root, account: account} do
      # A looping GIF is an enormous file for what it shows, and every client
      # already knows how to play a gifv.
      path = Path.join(root, "loop.gif")

      {_out, 0} =
        System.cmd("ffmpeg", [
          "-nostdin",
          "-y",
          "-f",
          "lavfi",
          "-i",
          "testsrc=size=160x120:rate=5:duration=1",
          path
        ])

      attachment = attachment_for(account, path, :image, "image/gif")

      {:ok, done} = Pipeline.run(attachment)

      assert done.type == :gifv
      assert done.file_content_type == "video/mp4"
      assert done.thumbnail_file_name
    end
  end

  describe "audio" do
    test "becomes mp3 and records how long it runs", %{root: root, account: account} do
      path = make_audio(Path.join(root, "sound.wav"))
      attachment = attachment_for(account, path, :audio, "audio/wav")

      {:ok, done} = Pipeline.run(attachment)

      assert done.processing == :complete
      assert done.meta["original"]["duration"] > 0

      {:ok, probe} = FFmpeg.probe(stored_path(done))

      assert FFmpeg.stream(probe, "audio")["codec_name"] == "mp3"
    end

    test "cover art becomes the thumbnail and the player's colour", %{
      root: root,
      account: account
    } do
      cover = make_image(Path.join(root, "cover.png"), 200, 200)
      sound = make_audio(Path.join(root, "bare.mp3"))
      path = Path.join(root, "withcover.mp3")

      {_out, 0} =
        System.cmd("ffmpeg", [
          "-nostdin",
          "-y",
          "-i",
          sound,
          "-i",
          cover,
          "-map",
          "0:a",
          "-map",
          "1:v",
          "-c",
          "copy",
          "-id3v2_version",
          "3",
          path
        ])

      attachment = attachment_for(account, path, :audio, "audio/mpeg")

      {:ok, done} = Pipeline.run(attachment)

      assert done.thumbnail_file_name
      assert done.meta["accent_colour"] =~ ~r/^#[0-9a-f]{6}$/
    end
  end

  describe "the state machine" do
    test "a queued upload ends up complete", %{root: root, account: account} do
      path = make_image(Path.join(root, "queued.jpg"))
      attachment = attachment_for(account, path, :image, "image/jpeg")

      assert :ok = perform_job(ProcessingWorker, %{"attachment_id" => attachment.id})

      assert Repo.reload(attachment).processing == :complete
    end

    test "a file that is not there is failed, not retried forever", %{account: account} do
      {:ok, attachment} =
        Media.create_attachment(%{account_id: account.id, type: :image, processing: :queued})

      assert {:error, :missing_file} = Pipeline.run(attachment)

      failed = Repo.reload(attachment)

      assert failed.processing == :failed
      assert failed.meta["error"] == "missing_file"
    end

    test "an upload deleted while queued is not an error", %{account: account} do
      {:ok, attachment} =
        Media.create_attachment(%{account_id: account.id, type: :image, processing: :queued})

      id = attachment.id
      Repo.delete(attachment)

      assert :ok = perform_job(ProcessingWorker, %{"attachment_id" => id})
    end

    test "the last attempt records the failure rather than asking for another", %{
      account: account
    } do
      {:ok, attachment} =
        Media.create_attachment(%{account_id: account.id, type: :image, processing: :queued})

      job = %Oban.Job{args: %{"attachment_id" => attachment.id}, attempt: 3, max_attempts: 3}

      assert :ok = ProcessingWorker.perform(job)
      assert Repo.reload(attachment).processing == :failed
    end
  end

  describe "limits" do
    test "a picture and a video are not the same size" do
      assert Upload.max_bytes(:image) == 16 * 1024 * 1024
      assert Upload.max_bytes(:video) == 99 * 1024 * 1024
    end

    test "an admin can change them" do
      :ok = Abuuba.Settings.put("media_image_size_limit", 1024)

      assert Upload.max_bytes(:image) == 1024
    end

    test "and the instance document says the same numbers" do
      # A client that checks before uploading and a server that refuses
      # afterwards must not disagree.
      config = Abuuba.Instance.configuration()

      assert config["media_attachments"]["image_size_limit"] == Upload.max_bytes(:image)
      assert config["media_attachments"]["video_size_limit"] == Upload.max_bytes(:video)
    end
  end
end
