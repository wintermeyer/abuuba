defmodule Abuuba.ReblogAggregationTest do
  use Abuuba.DataCase, async: true
  use Oban.Testing, repo: Abuuba.Repo

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Relationships
  alias Abuuba.Statuses
  alias Abuuba.Timelines.Feed
  alias Abuuba.Timelines.MaintenanceWorker

  setup do
    reader = account_fixture()
    original_author = account_fixture()
    original = status_fixture(%{account_id: original_author.id, text: "the popular post"})

    %{reader: reader, original: original}
  end

  defp boosting_friend(reader, original) do
    friend = account_fixture()
    {:ok, _} = Relationships.follow(reader, friend)
    {:ok, boost} = Statuses.boost(friend, original)

    boost
  end

  defp shown(reader), do: Feed.status_ids("home", reader.id, %{limit: 100})

  describe "several people boosting the same post" do
    test "shows it once", %{reader: reader, original: original} do
      # Five boosts of one post inside somebody's visible window is one thing
      # that happened, not five.
      first = boosting_friend(reader, original)
      second = boosting_friend(reader, original)
      third = boosting_friend(reader, original)

      ids = shown(reader)

      assert first.id in ids
      refute second.id in ids
      refute third.id in ids
    end

    test "keeps the hidden ones rather than dropping them", %{reader: reader, original: original} do
      # The one on show can go away, and a boost that was never stored could
      # not be promoted.
      boosting_friend(reader, original)
      second = boosting_friend(reader, original)

      assert Feed.count("home", reader.id) == 2
      refute second.id in shown(reader)
    end

    test "shows a boost of a different post", %{reader: reader, original: original} do
      other = status_fixture(%{account_id: account_fixture().id, text: "another post"})

      first = boosting_friend(reader, original)
      second = boosting_friend(reader, other)

      ids = shown(reader)

      assert first.id in ids
      assert second.id in ids
    end

    test "hides a boost of something already in the feed on its own", %{reader: reader} do
      # Somebody you follow wrote it, and somebody else you follow boosted it.
      # You have already read it.
      author = account_fixture()
      {:ok, _} = Relationships.follow(reader, author)

      original = status_fixture(%{account_id: author.id, text: "theirs"})
      boost = boosting_friend(reader, original)

      ids = shown(reader)

      assert original.id in ids
      refute boost.id in ids
    end
  end

  describe "when the one on show goes away" do
    test "a hidden one is promoted", %{reader: reader, original: original} do
      first = boosting_friend(reader, original)
      second = boosting_friend(reader, original)

      {:ok, _} = Statuses.delete_status(first)

      ids = shown(reader)

      refute first.id in ids
      assert second.id in ids
    end

    test "taking a boost back promotes the next one", %{reader: reader, original: original} do
      first = boosting_friend(reader, original)
      second = boosting_friend(reader, original)

      :ok = Statuses.unboost(first.account_id, original)

      assert second.id in shown(reader)
    end

    test "with nothing hidden behind it, nothing is promoted", %{
      reader: reader,
      original: original
    } do
      only = boosting_friend(reader, original)

      {:ok, _} = Statuses.delete_status(only)

      assert shown(reader) == []
    end

    test "promotes one, not all of them", %{reader: reader, original: original} do
      first = boosting_friend(reader, original)
      second = boosting_friend(reader, original)
      third = boosting_friend(reader, original)

      {:ok, _} = Statuses.delete_status(first)

      ids = shown(reader)

      assert length(Enum.filter([second.id, third.id], &(&1 in ids))) == 1
    end

    test "removing the shown one and its understudy together promotes the third", %{
      reader: reader,
      original: original
    } do
      # One removal can name both the entry on show and the one standing
      # behind it — purging an account takes its posts and boosts of them in
      # one sweep. The survivor still has to come forward.
      first = boosting_friend(reader, original)
      second = boosting_friend(reader, original)
      third = boosting_friend(reader, original)

      :ok = Feed.remove("home", reader.id, [first.id, second.id])

      assert shown(reader) == [third.id]
    end
  end

  describe "removals that are not deletions" do
    test "unfollowing the author promotes a boost of them", %{reader: reader} do
      # The original was showing and the boost was standing behind it. Taking
      # the original out without promoting leaves the boost hidden behind
      # something that is no longer there, which is a post that silently never
      # appears again.
      author = account_fixture()
      {:ok, _} = Relationships.follow(reader, author)

      original = status_fixture(%{account_id: author.id, text: "theirs"})
      boost = boosting_friend(reader, original)

      refute boost.id in shown(reader)

      :ok = Relationships.unfollow(reader, author)

      assert boost.id in shown(reader)
    end
  end

  describe "feed maintenance" do
    test "trims a feed that is over its cap", %{reader: reader} do
      for n <- 1..(Feed.limit() + 3), do: Feed.insert("home", reader.id, n)

      assert :ok = perform_job(MaintenanceWorker, %{})

      assert Feed.count("home", reader.id) == Feed.limit()
    end

    test "empties the feed of somebody who has not been here in a long time", %{reader: reader} do
      # A feed nobody has opened in months is the largest table on the server
      # holding rows for somebody who is not reading them. It is rebuilt if
      # they come back.
      user =
        user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

      {:ok, _} =
        user
        |> Ecto.Changeset.change(last_signed_in_at: DateTime.add(DateTime.utc_now(), -400, :day))
        |> Abuuba.Repo.update()

      Feed.insert("home", reader.id, 1)

      assert :ok = perform_job(MaintenanceWorker, %{})

      assert Feed.count("home", reader.id) == 0
    end

    test "leaves the feed of somebody who was here yesterday", %{reader: reader} do
      user =
        user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

      {:ok, _} =
        user
        |> Ecto.Changeset.change(last_signed_in_at: DateTime.add(DateTime.utc_now(), -1, :day))
        |> Abuuba.Repo.update()

      Feed.insert("home", reader.id, 1)

      assert :ok = perform_job(MaintenanceWorker, %{})

      assert Feed.count("home", reader.id) == 1
    end

    test "leaves a remote account's feed alone", %{} do
      # A remote follower has no user row and never signs in. Treating that as
      # dormant would empty the feed of everybody on every other server.
      remote = remote_account_fixture(%{domain: "remote.example"})
      Feed.insert("home", remote.id, 1)

      assert :ok = perform_job(MaintenanceWorker, %{})

      assert Feed.count("home", remote.id) == 1
    end

    test "clears out feeds belonging to accounts that are gone", %{} do
      # `feed_entries` names an account by id and nothing enforces that the
      # account still exists, so a deleted account leaves its rows behind.
      gone = account_fixture()
      Feed.insert("home", gone.id, 1)
      {:ok, _} = Accounts.delete_account(gone)

      assert :ok = perform_job(MaintenanceWorker, %{})

      assert Feed.count("home", gone.id) == 0
    end

    test "deleting an account takes its feed with it", %{} do
      # Without waiting for a sweeper, which is what somebody watching the
      # table size after a deletion expects.
      gone = account_fixture()
      Feed.insert("home", gone.id, 1)

      {:ok, _} = Accounts.delete_account(gone)

      assert Feed.count("home", gone.id) == 0
    end
  end
end
