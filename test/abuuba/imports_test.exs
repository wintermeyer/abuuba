defmodule Abuuba.ImportsTest do
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Imports
  alias Abuuba.Imports.Run
  alias Abuuba.Repo
  alias Abuuba.Statuses.Status
  alias Abuuba.Timelines.Feed

  @published "2019-04-01T10:00:00Z"

  setup do
    account = account_fixture()

    root = Path.join(System.tmp_dir!(), "abuuba-archives-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    %{account: account, root: root}
  end

  defp archive!(root, opts \\ []) do
    path = Path.join(root, "archive.zip")

    outbox = %{
      "type" => "OrderedCollection",
      "orderedItems" => Keyword.get(opts, :items, [note()])
    }

    files =
      [
        {~c"actor.json",
         Jason.encode!(%{
           "id" => "https://old.example/users/alice",
           "preferredUsername" => "alice"
         })},
        {~c"outbox.json", Jason.encode!(outbox)},
        {~c"likes.json", Jason.encode!(%{"orderedItems" => Keyword.get(opts, :likes, [])})},
        {~c"bookmarks.json", Jason.encode!(%{"orderedItems" => []})}
      ] ++ Keyword.get(opts, :extra, [])

    {:ok, _created} = :zip.create(to_charlist(path), files)

    path
  end

  defp note(overrides \\ %{}) do
    %{
      "type" => "Create",
      "object" =>
        Map.merge(
          %{
            "type" => "Note",
            "content" => "<p>an old post</p>",
            "published" => @published,
            "to" => ["https://www.w3.org/ns/activitystreams#Public"]
          },
          overrides
        )
    }
  end

  defp run!(account, path) do
    {:ok, archive_import} = Imports.start(account, %{path: path, filename: "archive.zip"})
    {:ok, finished} = Imports.run(archive_import)

    finished
  end

  describe "reading an archive back in" do
    test "makes a post that keeps its original date", %{account: account, root: root} do
      # The id is the date, so an imported profile reads in the order it was
      # written rather than arriving as a wall of posts dated today.
      finished = run!(account, archive!(root))

      status = Repo.one(Status)

      assert finished.state == "finished"
      assert status.text =~ "an old post"
      assert DateTime.to_iso8601(status.inserted_at) =~ "2019-04-01"
      assert status.id < Abuuba.Snowflake.generate()
    end

    test "stores what somebody wrote, not the old server's markup", %{
      account: account,
      root: root
    } do
      # A post of this account's own is plain text here and becomes HTML on the
      # way out. Storing the archive's markup instead means the reader sees a
      # `<p>` in the middle of the sentence.
      items = [
        note(%{
          "content" =>
            "<p>Two lines,<br>and a <a href=\"https://example.com\">link</a>.</p><p>A second paragraph.</p>"
        })
      ]

      run!(account, archive!(root, items: items))

      status = Repo.one(Status)

      assert status.text == "Two lines,\nand a link.\n\nA second paragraph."
      refute Abuuba.Statuses.content_html(status) =~ "&lt;"
    end

    test "and marks it as a copy of something posted somewhere else", %{
      account: account,
      root: root
    } do
      run!(account, archive!(root))

      refute is_nil(Repo.one(Status).imported_at)
    end

    test "keeps who a post was addressed to", %{account: account, root: root} do
      items = [
        note(%{"to" => [], "cc" => ["https://www.w3.org/ns/activitystreams#Public"]}),
        note(%{
          "published" => "2019-05-01T10:00:00Z",
          "to" => ["https://old.example/users/alice/followers"]
        })
      ]

      run!(account, archive!(root, items: items))

      assert [:unlisted, :private] =
               Status |> Repo.all() |> Enum.sort_by(& &1.id) |> Enum.map(& &1.visibility)
    end

    test "keeps every post of a thread written in the same second", %{
      account: account,
      root: root
    } do
      # An id is a time, so posts published in the same millisecond want the
      # same one. Without the next sequence, every post of every thread after
      # the first would be reported as one that could not be saved.
      items = [note(), note(), note()]

      finished = run!(account, archive!(root, items: items))

      assert finished.imported == 3
      assert finished.failures == []
      assert Repo.aggregate(Status, :count) == 3
    end

    test "does not put a decade of history in anybody's timeline", %{
      account: account,
      root: root
    } do
      # Everything downstream of a new post assumes it was published now.
      # Nobody's followers asked to be shown somebody else's history in one go.
      run!(account, archive!(root))

      assert Feed.count("home", account.id) == 0
    end

    test "carries a picture across from inside the archive", %{account: account, root: root} do
      path =
        archive!(root,
          items: [
            note(%{
              "attachment" => [
                %{
                  "url" => "media_attachments/files/000/000/001/original/pic.png",
                  "name" => "a description"
                }
              ]
            })
          ],
          extra: [{~c"media_attachments/files/000/000/001/original/pic.png", png()}]
        )

      run!(account, path)

      attachment = Repo.one(Abuuba.Media.Attachment)

      assert attachment.description == "a description"
      assert Repo.one(Status).ordered_media_attachment_ids == [attachment.id]
    end

    test "keeps the post when its picture is missing from the archive", %{
      account: account,
      root: root
    } do
      # An archive whose media never made it is still somebody's whole history.
      path =
        archive!(root,
          items: [
            note(%{"attachment" => [%{"url" => "media_attachments/files/gone.png"}]})
          ]
        )

      run!(account, path)

      assert Repo.one(Status)
      assert Repo.aggregate(Abuuba.Media.Attachment, :count) == 0
    end
  end

  describe "what cannot be carried over" do
    test "a boost is reported rather than guessed at", %{account: account, root: root} do
      # It names somebody else's post by address and the archive does not hold
      # it, so re-creating one would mean fetching from a server that may be
      # gone.
      items = [%{"type" => "Announce", "object" => "https://old.example/users/bob/statuses/1"}]

      finished = run!(account, archive!(root, items: items))

      assert [%{"reason" => "boosts_are_not_carried"}] = finished.failures
      assert Repo.aggregate(Status, :count) == 0
    end

    test "a poll is too, because its votes could not be true here", %{
      account: account,
      root: root
    } do
      items = [note(%{"type" => "Question"})]

      finished = run!(account, archive!(root, items: items))

      assert [%{"reason" => "polls_are_not_carried"}] = finished.failures
    end

    test "a post with no date cannot be placed", %{account: account, root: root} do
      items = [note(%{"published" => nil})]

      finished = run!(account, archive!(root, items: items))

      assert [%{"reason" => "no_date"}] = finished.failures
    end

    test "a favourite of a post nobody can find is named", %{account: account, root: root} do
      path = archive!(root, items: [], likes: ["https://gone.example/users/bob/statuses/1"])

      finished = run!(account, path)

      assert [%{"what" => what, "reason" => "could_not_be_fetched"}] = finished.failures
      assert what =~ "favourite"
    end

    test "one failure does not stop the rest", %{account: account, root: root} do
      items = [
        %{"type" => "Announce", "object" => "https://old.example/1"},
        note(%{"published" => "2019-06-01T10:00:00Z"})
      ]

      finished = run!(account, archive!(root, items: items))

      assert finished.imported == 1
      assert length(finished.failures) == 1
      assert Repo.aggregate(Status, :count) == 1
    end
  end

  describe "the run itself" do
    test "counts what it has done, so a progress bar means something", %{
      account: account,
      root: root
    } do
      items = [note(), note(%{"published" => "2019-06-01T10:00:00Z"})]

      finished = run!(account, archive!(root, items: items))

      assert finished.total == 2
      assert finished.done == 2
      assert finished.imported == 2
      refute is_nil(finished.finished_at)
    end

    test "announces its progress to whoever is watching", %{account: account, root: root} do
      :ok = Imports.subscribe(account)

      run!(account, archive!(root))

      assert_receive {:archive_import, %Run{state: "running"}}
      assert_receive {:archive_import, %Run{state: "finished"}}
    end

    test "refuses a second one while the first is still going", %{account: account, root: root} do
      # Two would race over the same posts and neither progress bar would mean
      # anything.
      {:ok, _first} = Imports.start(account, %{path: archive!(root), filename: "a.zip"})

      assert {:error, %Ecto.Changeset{}} =
               Imports.start(account, %{path: archive!(root), filename: "b.zip"})
    end

    test "removes the upload afterwards, whatever happened", %{account: account, root: root} do
      # It is a copy of everything somebody ever posted.
      path = archive!(root)

      run!(account, path)

      refute File.exists?(path)
    end

    test "says so when the file is not an archive at all", %{account: account, root: root} do
      path = Path.join(root, "notes.txt")
      File.write!(path, "not a zip")

      finished = run!(account, path)

      assert finished.state == "failed"
      assert [%{"reason" => "unreadable_archive"}] = finished.failures
    end
  end

  # The smallest valid PNG, so the media pipeline has something real to read.
  defp png do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
  end
end
