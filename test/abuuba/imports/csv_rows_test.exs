defmodule Abuuba.Imports.CSVRowsTest do
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Federation.URIs
  alias Abuuba.Filters
  alias Abuuba.Imports
  alias Abuuba.Lists
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Bookmark

  setup do
    account = account_fixture()
    other = account_fixture()

    root = Path.join(System.tmp_dir!(), "abuuba-csv-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    %{account: account, other: other, root: root}
  end

  defp run!(account, root, filename, contents, opts \\ []) do
    path = Path.join(root, filename)
    File.write!(path, contents)

    {:ok, run} =
      Imports.start(account, %{
        path: path,
        filename: filename,
        kind: "list",
        mode: Keyword.get(opts, :mode, "merge")
      })

    {:ok, finished} = Imports.run(run)

    finished
  end

  defp handle(account), do: "#{account.username}@#{URIs.local_domain()}"

  describe "a follow list" do
    test "follows everybody in it", %{account: account, other: other, root: root} do
      contents = "Account address,Show boosts,Notify on new posts\n#{handle(other)},true,false\n"

      finished = run!(account, root, "following_accounts.csv", contents)

      assert finished.state == "finished"
      assert finished.imported == 1
      assert Relationships.following?(account, other)
    end

    test "keeping what the file said about boosts", %{account: account, other: other, root: root} do
      contents = "Account address,Show boosts,Notify on new posts\n#{handle(other)},false,true\n"

      run!(account, root, "following_accounts.csv", contents)

      follow = Repo.get_by(Relationships.Follow, account_id: account.id)

      refute follow.show_reblogs
      assert follow.notify
    end

    test "names the ones nobody can find, and keeps going", %{
      account: account,
      other: other,
      root: root
    } do
      # A list from a server that closed names accounts on a hundred others,
      # and some of them will be gone.
      contents =
        "Account address\nnobody@gone.example\n#{handle(other)}\n"

      finished = run!(account, root, "following_accounts.csv", contents)

      assert finished.imported == 1
      assert [%{"what" => "nobody@gone.example"}] = finished.failures
      assert Relationships.following?(account, other)
    end

    test "is not a failure when it was already done", %{
      account: account,
      other: other,
      root: root
    } do
      # Somebody running an import twice is being careful, not making a
      # mistake.
      contents = "Account address\n#{handle(other)}\n"

      run!(account, root, "following_accounts.csv", contents)
      finished = run!(account, root, "following_accounts.csv", contents)

      assert finished.failures == []
      assert finished.imported == 1
    end
  end

  describe "the other lists" do
    test "blocks", %{account: account, other: other, root: root} do
      run!(account, root, "blocked_accounts.csv", "#{handle(other)}\n")

      assert Relationships.blocking?(account, other)
    end

    test "mutes, with what the file said about notifications", %{
      account: account,
      other: other,
      root: root
    } do
      contents = "Account address,Hide notifications\n#{handle(other)},false\n"

      run!(account, root, "muted_accounts.csv", contents)

      mute = Repo.get_by(Relationships.Mute, account_id: account.id)

      refute mute.hide_notifications
    end

    test "domain blocks", %{account: account, root: root} do
      run!(account, root, "blocked_domains.csv", "#domain\nbad.example\n")

      assert Relationships.blocking_domain?(account, "bad.example")
    end

    test "lists, creating the list and following whoever is in it", %{
      account: account,
      other: other,
      root: root
    } do
      contents = "List name,Account address\nFriends,#{handle(other)}\n"

      run!(account, root, "lists.csv", contents)

      assert [list] = Lists.all(account)
      assert list.title == "Friends"
      assert Relationships.following?(account, other)
    end

    test "filters, with the words they are about", %{account: account, root: root} do
      contents = "Title,Context,Keyword,Action\nSpoilers,home,ending,hide\n"

      run!(account, root, "filters.csv", contents)

      assert [filter] = Filters.all(account)
      assert filter.title == "Spoilers"
      assert filter.filter_action == "hide"
    end
  end

  describe "merge and overwrite" do
    test "merge leaves what is already there", %{account: account, other: other, root: root} do
      third = account_fixture()
      Relationships.follow(account, third)

      run!(account, root, "following_accounts.csv", "Account address\n#{handle(other)}\n")

      assert Relationships.following?(account, third)
      assert Relationships.following?(account, other)
    end

    test "overwrite makes what is here match the file", %{
      account: account,
      other: other,
      root: root
    } do
      # Somebody exported their list, edited it, and this is now the list.
      third = account_fixture()
      Relationships.follow(account, third)

      run!(account, root, "following_accounts.csv", "Account address\n#{handle(other)}\n",
        mode: "overwrite"
      )

      refute Relationships.following?(account, third)
      assert Relationships.following?(account, other)
    end

    test "and does not empty a bookmark list to apply a file of twelve", %{
      account: account,
      root: root
    } do
      # A reading list built over years is not something to clear on the way
      # to applying somebody's export.
      status = status_fixture(%{account_id: account_fixture().id})
      {:ok, _bookmarked} = Statuses.bookmark(account, status)

      run!(account, root, "bookmarks.csv", "https://gone.example/1\n", mode: "overwrite")

      assert Repo.get_by(Bookmark, account_id: account.id, status_id: status.id)
    end
  end

  describe "the file itself" do
    test "one nobody can identify is refused before anything is changed", %{
      account: account,
      root: root
    } do
      finished = run!(account, root, "mystery.csv", "bob@other.example\n")

      assert finished.state == "failed"
      assert [%{"reason" => "unknown_list"}] = finished.failures
    end

    test "and the upload is removed either way", %{account: account, root: root} do
      path = Path.join(root, "blocked_accounts.csv")
      File.write!(path, "bob@other.example\n")

      {:ok, run} =
        Imports.start(account, %{path: path, filename: "blocked_accounts.csv", kind: "list"})

      {:ok, _finished} = Imports.run(run)

      refute File.exists?(path)
    end
  end
end
