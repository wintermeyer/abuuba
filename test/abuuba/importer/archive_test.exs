defmodule Abuuba.Importer.ArchiveTest do
  use ExUnit.Case, async: true

  alias Abuuba.Importer.Archive

  setup do
    root = Path.join(System.tmp_dir!(), "abuuba-archive-#{System.unique_integer([:positive])}")
    into = Path.join(root, "unpacked")

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, into: into}
  end

  defp actor do
    %{
      "id" => "https://old.example/users/alice",
      "preferredUsername" => "alice",
      "outbox" => "outbox.json",
      "likes" => "likes.json",
      "bookmarks" => "bookmarks.json",
      "icon" => %{"url" => "avatar.png"}
    }
  end

  defp outbox do
    %{
      "type" => "OrderedCollection",
      "orderedItems" => [
        %{
          "type" => "Create",
          "object" => %{
            "type" => "Note",
            "content" => "<p>hello</p>",
            "published" => "2019-04-01T10:00:00Z",
            "attachment" => [
              %{"url" => "media_attachments/files/000/000/001/original/pic.jpg"}
            ]
          }
        }
      ]
    }
  end

  # Written with the same tool a real export is: the shape of the file is the
  # thing under test, so building it by hand would only prove the test agrees
  # with itself.
  defp zip!(root, files) do
    path = Path.join(root, "archive.zip")

    entries =
      Enum.map(files, fn {name, contents} -> {to_charlist(name), contents} end)

    {:ok, _created} = :zip.create(to_charlist(path), entries)

    path
  end

  defp tar!(root, files) do
    path = Path.join(root, "archive.tar.gz")

    entries = Enum.map(files, fn {name, contents} -> {to_charlist(name), contents} end)

    :ok = :erl_tar.create(to_charlist(path), entries, [:compressed])

    path
  end

  defp default_files do
    [
      {"actor.json", Jason.encode!(actor())},
      {"outbox.json", Jason.encode!(outbox())},
      {"likes.json",
       Jason.encode!(%{"orderedItems" => ["https://old.example/users/bob/statuses/1"]})},
      {"bookmarks.json", Jason.encode!(%{"orderedItems" => []})},
      {"media_attachments/files/000/000/001/original/pic.jpg", "JPEG"}
    ]
  end

  describe "opening one" do
    test "reads the four documents out of a zip", %{root: root, into: into} do
      path = zip!(root, default_files())

      assert {:ok, archive} = Archive.open(path, into)

      assert archive.actor["preferredUsername"] == "alice"
      assert [%{"type" => "Create"}] = archive.outbox
      assert archive.likes == ["https://old.example/users/bob/statuses/1"]
      assert archive.bookmarks == []
    end

    test "and out of the tar.gz an older server wrote", %{root: root, into: into} do
      # Somebody's only copy of a server that closed years ago is in whatever
      # format that server used, which is the whole reason to read both.
      path = tar!(root, default_files())

      assert {:ok, archive} = Archive.open(path, into)

      assert archive.actor["preferredUsername"] == "alice"
      assert length(archive.outbox) == 1
    end

    test "even when the file is named wrongly", %{root: root, into: into} do
      # The extension is a hint from whoever named it, not a fact.
      path = zip!(root, default_files())
      renamed = Path.join(root, "export.bin")
      File.rename!(path, renamed)

      assert {:ok, _archive} = Archive.open(renamed, into)
    end

    test "does not let an archive write outside the directory it was given", %{
      root: root,
      into: into
    } do
      # The runtime refuses the path rather than this code, which is exactly
      # why it is worth a test: the guarantee belongs to a dependency and a
      # dependency can change.
      path = Path.join(root, "evil.zip")
      escape = Path.join(root, "escaped.txt")

      {:ok, _created} =
        :zip.create(to_charlist(path), [
          {~c"actor.json", Jason.encode!(actor())},
          {~c"../escaped.txt", "gotcha"}
        ])

      {:ok, _archive} = Archive.open(path, into)

      refute File.exists?(escape)
    end

    test "and neither does a tar", %{root: root, into: into} do
      path = Path.join(root, "evil.tar.gz")
      escape = Path.join(root, "escaped.txt")

      :ok =
        :erl_tar.create(to_charlist(path), [{~c"../escaped.txt", "gotcha"}], [:compressed])

      assert {:error, :unreadable_archive} = Archive.open(path, into)
      refute File.exists?(escape)
    end

    test "refuses one that unpacks to more than it is allowed to", %{root: root, into: into} do
      # The size in the archive is written by whoever built it, so it is the
      # size on the disk afterwards that decides.
      path = zip!(root, [{"actor.json", Jason.encode!(actor())}])

      assert {:error, :archive_too_large} = Archive.open(path, into, max_bytes: 10)
    end

    test "refuses something that is not an archive at all", %{root: root, into: into} do
      path = Path.join(root, "notes.txt")
      File.write!(path, "just some text")

      assert {:error, :unreadable_archive} = Archive.open(path, into)
    end

    test "refuses one with no actor document", %{root: root, into: into} do
      path = zip!(root, [{"outbox.json", Jason.encode!(outbox())}])

      assert {:error, :unreadable_archive} = Archive.open(path, into)
    end

    test "treats a missing likes file as nobody having favourited anything", %{
      root: root,
      into: into
    } do
      path = zip!(root, [{"actor.json", Jason.encode!(actor())}])

      assert {:ok, archive} = Archive.open(path, into)

      assert archive.likes == []
      assert archive.outbox == []
    end
  end

  describe "the files inside" do
    setup %{root: root, into: into} do
      {:ok, archive} = Archive.open(zip!(root, default_files()), into)

      %{archive: archive}
    end

    test "an attachment is found at the path its post names", %{archive: archive} do
      path = Archive.file(archive, "media_attachments/files/000/000/001/original/pic.jpg")

      assert File.read!(path) == "JPEG"
    end

    test "a path that climbs out of the archive is not a file", %{archive: archive} do
      # This is a file somebody uploaded. Nothing in it is believed.
      assert is_nil(Archive.file(archive, "../../etc/passwd"))
      assert is_nil(Archive.file(archive, "/etc/passwd"))
    end

    test "and neither is one that is not there", %{archive: archive} do
      assert is_nil(Archive.file(archive, "media_attachments/files/nope.jpg"))
      assert is_nil(Archive.file(archive, nil))
    end

    test "says whose archive it is" do
      archive = %Archive{actor: actor(), root: "/tmp", outbox: [], likes: [], bookmarks: []}

      assert Archive.handle(archive) == "alice@old.example"
    end
  end
end
