defmodule Abuuba.Importer.MediaFilesTest do
  use Abuuba.DataCase, async: false

  alias Abuuba.Accounts.Account
  alias Abuuba.Importer.MediaFiles
  alias Abuuba.Media.Attachment
  alias Abuuba.Media.Storage
  alias Abuuba.Repo

  setup do
    source =
      Path.join(System.tmp_dir!(), "abuuba-import-source-#{System.unique_integer([:positive])}")

    destination =
      Path.join(System.tmp_dir!(), "abuuba-import-dest-#{System.unique_integer([:positive])}")

    File.mkdir_p!(source)

    previous = Application.get_env(:abuuba, :media_root)
    Application.put_env(:abuuba, :media_root, destination)

    on_exit(fn ->
      Application.put_env(:abuuba, :media_root, previous)
      File.rm_rf!(source)
      File.rm_rf!(destination)
    end)

    %{source: source, destination: destination}
  end

  defp write!(root, relative, contents) do
    path = Path.join(root, relative)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)

    path
  end

  describe "copying the tree" do
    test "puts a file where the row already says it is", %{source: source, destination: dest} do
      # The two servers lay media out the same way, which is the whole reason a
      # takeover can copy the tree rather than rewrite every row.
      write!(source, "media_attachments/files/000/000/600/original/picture.jpg", "jpeg")

      :ok = MediaFiles.run(media_root: source)

      assert File.read!(
               Path.join(dest, "media_attachments/files/000/000/600/original/picture.jpg")
             ) == "jpeg"
    end

    test "brings emojis and preview card images too", %{source: source, destination: dest} do
      write!(source, "custom_emojis/images/000/000/020/original/party.png", "png")
      write!(source, "preview_cards/images/000/000/650/original/card.png", "png")

      :ok = MediaFiles.run(media_root: source)

      assert File.exists?(Path.join(dest, "custom_emojis/images/000/000/020/original/party.png"))
      assert File.exists?(Path.join(dest, "preview_cards/images/000/000/650/original/card.png"))
    end

    test "leaves other servers' cached files behind", %{source: source, destination: dest} do
      # It is a cache. It can be fetched again, it is usually the larger half of
      # the disk, and the first sweep would delete it anyway.
      write!(source, "media_attachments/cache/files/000/000/700/original/theirs.jpg", "jpeg")
      write!(source, "media_attachments/files/000/000/600/original/mine.jpg", "jpeg")

      :ok = MediaFiles.run(media_root: source)

      refute File.exists?(Path.join(dest, "media_attachments/cache"))

      assert File.exists?(
               Path.join(dest, "media_attachments/files/000/000/600/original/mine.jpg")
             )
    end

    test "leaves the source exactly as it was", %{source: source} do
      # A rehearsal has to be repeatable, and an import that consumed its input
      # could only be run once.
      path = write!(source, "media_attachments/files/000/000/600/original/picture.jpg", "jpeg")

      :ok = MediaFiles.run(media_root: source)

      assert File.exists?(path)
    end

    test "does not copy a file that is already there", %{source: source, destination: dest} do
      write!(source, "media_attachments/files/000/000/600/original/picture.jpg", "jpeg")
      write!(dest, "media_attachments/files/000/000/600/original/picture.jpg", "jpeg")

      copied = :counters.new(1, [])

      :ok =
        MediaFiles.run(
          media_root: source,
          copier: fn from, to ->
            :counters.add(copied, 1, 1)
            File.copy(from, to)
          end
        )

      assert :counters.get(copied, 1) == 0
    end

    test "does copy one that arrived half-written", %{source: source, destination: dest} do
      # Same size is the same file; a shorter one is a copy that stopped.
      write!(source, "media_attachments/files/000/000/600/original/picture.jpg", "jpeg")
      write!(dest, "media_attachments/files/000/000/600/original/picture.jpg", "jp")

      :ok = MediaFiles.run(media_root: source)

      assert File.read!(
               Path.join(dest, "media_attachments/files/000/000/600/original/picture.jpg")
             ) == "jpeg"
    end

    test "does nothing at all when no media root was named", %{destination: dest} do
      :ok = MediaFiles.run([])

      refute File.exists?(dest)
    end
  end

  describe "checking first" do
    test "refuses a directory that is not a media root", %{source: source} do
      # An import that copies every row and no file is one where every image is
      # broken and nobody notices until somebody scrolls.
      assert [%{key: "media_root"}] = MediaFiles.check(media_root: source)
    end

    test "and passes one that is", %{source: source} do
      File.mkdir_p!(Path.join(source, "media_attachments"))

      assert MediaFiles.check(media_root: source) == []
    end

    test "says nothing when there is no root to check" do
      assert MediaFiles.check([]) == []
    end
  end

  describe "verifying" do
    setup %{source: source} do
      Repo.insert_all(Account, [
        %{
          id: 1,
          username: "alice",
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ])

      Repo.insert_all(Attachment, [
        %{
          id: 600,
          account_id: 1,
          type: :image,
          processing: :complete,
          file_file_name: "picture.jpg",
          meta: %{},
          remote_url: "",
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ])

      %{source: source}
    end

    test "asks the storage layer, the way a browser will", %{source: source} do
      write!(source, "media_attachments/files/000/000/600/original/picture.jpg", "jpeg")

      :ok = MediaFiles.run(media_root: source)

      assert [%{name: "media files", checked: 1, failures: []}] = MediaFiles.verify([])
    end

    test "names the attachment whose file never arrived" do
      assert [%{failures: [%{id: 600, was: "picture.jpg"}]}] = MediaFiles.verify([])
    end
  end

  test "the key the row produces is the path the file was copied to", %{source: source} do
    # The claim the whole step rests on, checked rather than asserted in prose.
    write!(source, "media_attachments/files/000/000/600/original/picture.jpg", "jpeg")

    attachment = %Attachment{id: 600, file_file_name: "picture.jpg", remote_url: ""}

    assert Storage.key_for(attachment, :original) ==
             "media_attachments/files/000/000/600/original/picture.jpg"
  end
end
