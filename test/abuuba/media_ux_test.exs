defmodule Abuuba.MediaUXTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Preferences
  alias Abuuba.Instance
  alias Abuuba.Media
  alias Abuuba.Media.Blurhash
  alias Abuuba.Media.Storage
  alias Abuuba.Media.Upload
  alias Abuuba.Statuses

  setup do
    %{author: account_fixture()}
  end

  defp upload(author, name \\ "photo.png", type \\ "image/png") do
    path = Path.join(System.tmp_dir!(), "media-ux-#{System.unique_integer([:positive])}")
    File.write!(path, "not really an image, but a real file")

    {:ok, attachment} =
      Media.upload(author, %{path: path, filename: name, content_type: type})

    attachment
  end

  describe "the placeholder colour" do
    test "reads the average colour a blurhash carries" do
      # The first characters of a blurhash are its average colour, which is all
      # a placeholder needs: the rest describes detail nobody sees behind a
      # loading image.
      assert Blurhash.average_colour("LEHV6nWB2yk8pyo0adR*.7kCMdnj") == "#979695"
    end

    test "a different hash is a different colour" do
      one = Blurhash.average_colour("LEHV6nWB2yk8pyo0adR*.7kCMdnj")
      two = Blurhash.average_colour("LKO2?U%2Tw=w]~RBVZRi};RPxuwH")

      assert one != two
    end

    test "refuses a string that is not one" do
      # An attachment's blurhash comes from another server as often as from
      # ours, so nothing here may assume it is well formed.
      assert Blurhash.average_colour("nope") == nil
      assert Blurhash.average_colour("") == nil
      assert Blurhash.average_colour(nil) == nil
      assert Blurhash.average_colour("!!!!!!") == nil
    end
  end

  defp write_temp(contents) do
    path = Path.join(System.tmp_dir!(), "media-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    path
  end

  describe "a thumbnail for a video" do
    test "is stored and recorded", %{author: author} do
      video = upload(author, "clip.mp4", "video/mp4")

      path = Path.join(System.tmp_dir!(), "thumb-#{System.unique_integer([:positive])}")
      File.write!(path, "a picture of the first frame")

      assert {:ok, updated} =
               Media.put_thumbnail(video, %{
                 path: path,
                 filename: "thumb.png",
                 content_type: "image/png"
               })

      assert updated.thumbnail_file_name
      assert updated.thumbnail_content_type == "image/png"
      assert updated.thumbnail_file_size > 0
    end

    test "replacing one takes the old picture off the disk", %{author: author} do
      # The storage key carries a random filename, so a second thumbnail is
      # written beside the first rather than over it. Nothing points at the
      # first afterwards, and no sweep can find it: the row it would have been
      # found by now names the new one.
      video = upload(author, "clip.mp4", "video/mp4")

      first_path = Path.join(System.tmp_dir!(), "thumb-#{System.unique_integer([:positive])}")
      File.write!(first_path, "the first frame")

      {:ok, with_first} =
        Media.put_thumbnail(video, %{
          path: first_path,
          filename: "first.png",
          content_type: "image/png"
        })

      old_key = Storage.key_for(with_first, :small)
      assert Storage.exists?(old_key)

      second_path = Path.join(System.tmp_dir!(), "thumb-#{System.unique_integer([:positive])}")
      File.write!(second_path, "a better frame")

      {:ok, with_second} =
        Media.put_thumbnail(with_first, %{
          path: second_path,
          filename: "second.png",
          content_type: "image/png"
        })

      new_key = Storage.key_for(with_second, :small)

      assert Storage.exists?(new_key), "the replacement was not stored"
      refute new_key == old_key
      refute Storage.exists?(old_key), "the picture it replaced is still on the disk"
    end

    test "and processing again does not leave the previous derived one", %{author: author} do
      # `mix abuuba.media refresh` reprocesses attachments in bulk, and each pass
      # derives a thumbnail under a new random name. One leaked picture per
      # attachment per refresh is a directory nobody can reconcile.
      video = upload(author, "clip.mp4", "video/mp4")

      {:ok, first} =
        Media.finish_processing(video, %{
          thumbnail: %{name: "first.png", size: 10, content_type: "image/png"}
        })

      old_key = Storage.key_for(first, :small)
      :ok = Storage.put(old_key, write_temp("derived once"))
      assert Storage.exists?(old_key)

      {:ok, second} =
        Media.finish_processing(first, %{
          thumbnail: %{name: "second.png", size: 12, content_type: "image/png"}
        })

      new_key = Storage.key_for(second, :small)
      :ok = Storage.put(new_key, write_temp("derived again"))

      assert Storage.exists?(new_key)
      refute Storage.exists?(old_key), "the thumbnail the last pass derived is still there"
    end

    test "refuses a thumbnail that is not a picture", %{author: author} do
      # A video handed in as a thumbnail would be served where an image is
      # expected, and a browser would render neither.
      video = upload(author, "clip.mp4", "video/mp4")

      path = Path.join(System.tmp_dir!(), "thumb-#{System.unique_integer([:positive])}")
      File.write!(path, "not a picture")

      assert {:error, :unsupported} =
               Media.put_thumbnail(video, %{
                 path: path,
                 filename: "clip.mp4",
                 content_type: "video/mp4"
               })
    end

    test "refuses one for an upload that is already posted", %{author: author} do
      # Changing a posted attachment's picture would change it here and nowhere
      # else, because the copies were already delivered.
      attachment = upload(author, "clip.mp4", "video/mp4")

      {:ok, status} = Statuses.create_status(%{account_id: author.id, text: "with a video"})
      {:ok, _} = Media.attach(status, [attachment.id])

      path = Path.join(System.tmp_dir!(), "thumb-#{System.unique_integer([:positive])}")
      File.write!(path, "a picture")

      assert {:error, :already_posted} =
               Media.put_thumbnail(Media.get_attachment(attachment.id), %{
                 path: path,
                 filename: "thumb.png",
                 content_type: "image/png"
               })
    end
  end

  describe "what a picker offers" do
    test "offers an extension for every type this server takes" do
      # A type with no extension of its own was stored as ".bin", which a
      # browser then refuses to render whatever it actually is.
      # Every one has to resolve to a type, or LiveView's `allow_upload` refuses
      # the whole filter and no file of any kind can be attached.
      for extension <- Upload.accepted_extensions() do
        assert MIME.from_path("file" <> extension) != "application/octet-stream",
               "#{extension} resolves to nothing; add it to the :mime config"
      end

      refute ".bin" in Upload.accepted_extensions()
      assert ".mov" in Upload.accepted_extensions()
      assert ".m4a" in Upload.accepted_extensions()
    end

    test "a file whose name carries no extension keeps the one its type implies", %{
      author: author
    } do
      path = Path.join(System.tmp_dir!(), "noext-#{System.unique_integer([:positive])}")
      File.write!(path, "a clip")

      {:ok, attachment} =
        Media.upload(author, %{path: path, filename: "clip", content_type: "video/quicktime"})

      assert String.ends_with?(attachment.file_file_name, ".mov")
    end
  end

  describe "the missing-alt-text reminder" do
    test "is a preference somebody can set" do
      assert "warn_missing_alt" in Preferences.keys()
    end

    test "is off until somebody asks for it" do
      # A confirmation nobody chose is a dialog in the way of posting.
      refute Preferences.defaults()["warn_missing_alt"]
    end

    test "is remembered once set" do
      settings = Preferences.merge(%{}, %{"warn_missing_alt" => true})

      assert Preferences.for_user(%{settings: settings})["warn_missing_alt"]
    end
  end

  describe "how many one post carries" do
    test "refuses more than the ceiling", %{author: author} do
      # Enforced where the attaching happens rather than only in the composer,
      # so no other path can hang twenty pictures on one post.
      ids = for _ <- 1..(Instance.max_media_attachments() + 1), do: upload(author).id

      {:ok, status} = Statuses.create_status(%{account_id: author.id, text: "too many"})

      assert {:error, :too_many_attachments} = Media.attach(status, ids)
      assert Media.for_status(status) == []
    end
  end

  describe "putting attachments in order" do
    test "records the order the author chose", %{author: author} do
      one = upload(author)
      two = upload(author)
      three = upload(author)

      {:ok, status} = Statuses.create_status(%{account_id: author.id, text: "three of them"})
      {:ok, status} = Media.attach(status, [three.id, one.id, two.id])

      assert Enum.map(Media.for_status(status), & &1.id) == [three.id, one.id, two.id]
    end
  end
end
