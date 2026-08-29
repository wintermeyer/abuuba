defmodule Abuuba.Statuses.PruneTest do
  @moduledoc """
  Which old remote posts may go, and the far longer list of which may not.

  Every "is removed" case here has a matching "is kept" case built the same way
  with one thing added, because a prune that removes nothing passes every
  keep-test on its own.
  """

  use Abuuba.DataCase, async: true

  import Ecto.Query
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Lists
  alias Abuuba.Notifications
  alias Abuuba.Repo
  alias Abuuba.Statuses.Prune
  alias Abuuba.Statuses.Status
  alias Abuuba.Timelines.Feed

  @cutoff_days 90

  defp ancient(status) do
    old = DateTime.add(DateTime.utc_now(), -365, :day)

    Repo.update_all(from(s in Status, where: s.id == ^status.id),
      set: [inserted_at: old, updated_at: old]
    )

    status
  end

  defp remote_status(attrs \\ %{}) do
    account = account_fixture(%{domain: "far.example", uri: "https://far.example/a"})

    attrs
    |> Map.put(:account_id, account.id)
    |> Map.put(:local, false)
    |> status_fixture()
  end

  defp removable_ids do
    @cutoff_days |> Prune.cutoff() |> Prune.removable_ids()
  end

  describe "what goes" do
    test "an old remote post nothing here refers to" do
      status = ancient(remote_status())

      assert status.id in removable_ids()
    end

    test "and removing it actually removes it" do
      status = ancient(remote_status())

      assert {:ok, 1} = Prune.remove(Prune.cutoff(@cutoff_days))
      refute Repo.get(Status, status.id)
    end
  end

  describe "what stays" do
    test "a post from here, however old" do
      status = ancient(status_fixture())

      refute status.id in removable_ids()
    end

    test "a remote post younger than the cutoff" do
      status = remote_status()

      refute status.id in removable_ids()
    end

    test "one somebody here favourited" do
      status = ancient(remote_status())
      favourite(status)

      refute status.id in removable_ids()
    end

    test "one somebody here bookmarked" do
      status = ancient(remote_status())
      bookmark(status)

      refute status.id in removable_ids()
    end

    test "one somebody here boosted" do
      status = ancient(remote_status())

      ancient(status_fixture(%{reblog_of_id: status.id, text: ""}))

      refute status.id in removable_ids()
    end

    test "one somebody here replied to" do
      status = ancient(remote_status())

      ancient(status_fixture(%{in_reply_to_id: status.id}))

      refute status.id in removable_ids()
    end

    test "one still sitting in somebody's timeline" do
      status = ancient(remote_status())
      feed_entry(status)

      refute status.id in removable_ids()
    end

    test "not one sitting only in the remote author's own feed" do
      # `feed_entries` can hold a home-feed row for an account on another
      # server: fan-out wrote one for every author until that was fixed, and a
      # server upgraded from an older version has them until the migration
      # clears them. A timeline rule that does not ask whose timeline it is
      # matches every one of those and prunes nothing, while still reporting
      # success.
      status = ancient(remote_status())
      Feed.insert("home", status.account_id, status.id)

      assert status.id in removable_ids()
    end

    test "one somebody here put in a list" do
      status = ancient(remote_status())
      Feed.insert("list", list_fixture().id, status.id)

      refute status.id in removable_ids()
    end

    test "one that mentions somebody here" do
      status = ancient(remote_status())
      mention(status, account_fixture())

      refute status.id in removable_ids()
    end

    test "one a notification points at" do
      status = ancient(remote_status())
      notification(status)

      refute status.id in removable_ids()
    end

    test "a direct message, whatever anybody has done with it" do
      status = ancient(remote_status(%{visibility: :direct}))

      refute status.id in removable_ids()
    end

    test "a limited post, for the same reason" do
      status = ancient(remote_status(%{visibility: :limited}))

      refute status.id in removable_ids()
    end

    test "one in a conversation somebody here is in" do
      status = ancient(remote_status())
      conversation_row(status)

      refute status.id in removable_ids()
    end

    test "one that is the subject of a report" do
      status = ancient(remote_status())
      report(status)

      refute status.id in removable_ids()
    end
  end

  describe "threads" do
    test "the whole ancestry of a kept post stays, not just its parent" do
      # grandparent <- parent <- child, all remote and all ancient, and the
      # child is the only one anybody here touched. Deleting the grandparent
      # would leave a thread that cannot be read from the top.
      grandparent = ancient(remote_status())
      parent = ancient(remote_status(%{in_reply_to_id: grandparent.id}))
      child = ancient(remote_status(%{in_reply_to_id: parent.id}))

      favourite(child)

      removable = removable_ids()

      refute grandparent.id in removable
      refute parent.id in removable
      refute child.id in removable
    end

    test "a thread nobody here touched goes in full" do
      # The positive control for the case above: the same shape, minus the
      # favourite. If this ever fails, the ancestry rule has stopped
      # distinguishing and is simply keeping everything.
      grandparent = ancient(remote_status())
      parent = ancient(remote_status(%{in_reply_to_id: grandparent.id}))
      child = ancient(remote_status(%{in_reply_to_id: parent.id}))

      removable = removable_ids()

      assert grandparent.id in removable
      assert parent.id in removable
      assert child.id in removable
    end

    test "a post whose boost is kept stays, because deleting it deletes the boost" do
      original = ancient(remote_status())
      boost = ancient(remote_status(%{reblog_of_id: original.id, text: ""}))

      feed_entry(boost)

      removable = removable_ids()

      refute original.id in removable
      refute boost.id in removable
    end
  end

  describe "removing" do
    test "takes the feed rows pointing at what it removed" do
      # `feed_entries.status_id` has no foreign key, so nothing cleans up after
      # a delete. A row can name a post being pruned without saving it — the
      # remote author's own feed, which no reader can open — and it would
      # outlive the post it names.
      status = ancient(remote_status())
      Feed.insert("home", status.account_id, status.id)

      assert feed_rows_for(status) > 0
      assert {:ok, 1} = Prune.remove(Prune.cutoff(@cutoff_days))
      assert feed_rows_for(status) == 0
    end

    test "leaves the feed rows of a post it kept" do
      status = ancient(remote_status())
      feed_entry(status)

      assert {:ok, 0} = Prune.remove(Prune.cutoff(@cutoff_days))
      assert feed_rows_for(status) > 0
    end
  end

  describe "counting" do
    test "the dry run and the deletion agree" do
      Enum.each(1..3, fn _index -> ancient(remote_status()) end)

      cutoff = Prune.cutoff(@cutoff_days)
      counted = Prune.count(cutoff)

      assert {:ok, removed} = Prune.remove(cutoff)
      assert removed == counted
      assert removed == 3
    end
  end

  ## Fixtures for the things that keep a post alive

  defp favourite(status) do
    Repo.insert_all("favourites", [
      %{
        account_id: account_fixture().id,
        status_id: status.id,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])
  end

  defp bookmark(status) do
    Repo.insert_all("bookmarks", [
      %{
        account_id: account_fixture().id,
        status_id: status.id,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])
  end

  defp feed_entry(status) do
    Feed.insert("home", account_fixture().id, status.id)
  end

  defp mention(status, account) do
    Repo.insert_all("mentions", [
      %{
        status_id: status.id,
        account_id: account.id,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])
  end

  defp notification(status) do
    {:ok, _notification} =
      Notifications.notify(account_fixture(), status.account_id, "mention", status_id: status.id)
  end

  defp feed_rows_for(status) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM feed_entries WHERE status_id = $1", [status.id])

    count
  end

  defp conversation_row(status) do
    conversation = conversation_fixture()

    Repo.update_all(from(s in Status, where: s.id == ^status.id),
      set: [conversation_id: conversation.id]
    )

    Repo.insert_all("account_conversations", [
      %{
        id: System.unique_integer([:positive]),
        account_id: account_fixture().id,
        conversation_id: conversation.id,
        participant_account_ids: [status.account_id],
        status_ids: [status.id],
        last_status_id: status.id,
        unread: false,
        muted: false,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])
  end

  defp list_fixture do
    {:ok, list} = Lists.create(account_fixture(), %{"title" => "reading"})

    list
  end

  defp report(status) do
    Repo.insert_all("reports", [
      %{
        account_id: account_fixture().id,
        target_account_id: status.account_id,
        status_ids: [status.id],
        comment: "",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])
  end
end
