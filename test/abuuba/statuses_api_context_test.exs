defmodule Abuuba.StatusesAPIContextTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Statuses
  alias Abuuba.Statuses.IdempotencyKey
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.ScheduledStatus
  alias Abuuba.Statuses.Status

  defp reply_to(parent, account, attrs \\ %{}) do
    status_fixture(
      Map.merge(
        %{
          account_id: account.id,
          in_reply_to_id: parent.id,
          in_reply_to_account_id: parent.account_id,
          conversation_id: parent.conversation_id
        },
        attrs
      )
    )
  end

  describe "the thread around a status" do
    setup do
      author = account_fixture()
      root = status_fixture(%{account_id: author.id, text: "root"})

      %{author: author, root: root}
    end

    test "leaves out a reply from somebody the reader will not deal with", %{
      root: root,
      author: author
    } do
      # A thread is where a block is most visible: open the post and there they
      # are, replying. Every timeline and the search box already answer this;
      # the thread asked only whether a post was addressed widely enough.
      reader = account_fixture()
      blocked = account_fixture()
      muted = account_fixture()

      hidden_reply = reply_to(root, blocked)
      muted_reply = reply_to(root, muted)
      ordinary = reply_to(root, author)

      {:ok, _} = Abuuba.Relationships.block(reader, blocked)
      {:ok, _} = Abuuba.Relationships.mute(reader, muted)

      %{descendants: shown} = Statuses.context(root, reader)
      ids = Enum.map(shown, & &1.id)

      # The positive control: an unrelated reply is still there, so this is a
      # filter rather than a thread that stopped loading.
      assert ordinary.id in ids
      refute hidden_reply.id in ids
      refute muted_reply.id in ids
    end

    test "and one from somebody who blocked the reader", %{root: root, author: author} do
      reader = account_fixture()
      blocker = account_fixture()

      theirs = reply_to(root, blocker)
      ordinary = reply_to(root, author)

      {:ok, _} = Abuuba.Relationships.block(blocker, reader)

      ids = root |> Statuses.context(reader) |> Map.get(:descendants) |> Enum.map(& &1.id)

      assert ordinary.id in ids
      refute theirs.id in ids
    end

    test "has no ancestors at the root", %{root: root, author: author} do
      assert %{ancestors: [], descendants: []} = Statuses.context(root, author)
    end

    test "walks every step back to the root, in order", %{root: root, author: author} do
      first = reply_to(root, author)
      second = reply_to(first, author)
      third = reply_to(second, author)

      %{ancestors: ancestors} = Statuses.context(third, author)

      assert Enum.map(ancestors, & &1.id) == [root.id, first.id, second.id]
    end

    test "collects every branch below, not only the first", %{root: root, author: author} do
      # A thread is a tree. Following one child would show a reader half a
      # conversation and give them no way to tell that is what happened.
      left = reply_to(root, author)
      right = reply_to(root, author)
      deep = reply_to(left, author)

      %{descendants: descendants} = Statuses.context(root, author)

      assert Enum.sort(Enum.map(descendants, & &1.id)) ==
               Enum.sort([left.id, right.id, deep.id])
    end

    test "leaves out what the reader may not see", %{root: root, author: author} do
      stranger = account_fixture()
      private = reply_to(root, author, %{visibility: :private})

      %{descendants: descendants} = Statuses.context(root, stranger)

      refute private.id in Enum.map(descendants, & &1.id)
    end

    test "leaves out what was deleted", %{root: root, author: author} do
      reply = reply_to(root, author)
      {:ok, _} = Statuses.delete_status(reply)

      assert %{descendants: []} = Statuses.context(root, author)
    end

    test "stops rather than looping when a thread points at itself" do
      # A remote peer can send a reply whose parent is the reply. Nothing
      # legitimate does it, and a recursive walk that trusts the data hangs.
      author = account_fixture()
      one = status_fixture(%{account_id: author.id})
      two = reply_to(one, author)

      Abuuba.Repo.update_all(
        from(s in Abuuba.Statuses.Status, where: s.id == ^one.id),
        set: [in_reply_to_id: two.id]
      )

      assert %{ancestors: ancestors} = Statuses.context(two, author)
      assert length(ancestors) <= 2
    end

    test "does not collect a thread of unbounded width", %{root: root, author: author} do
      # Depth is one bound, breadth is the other: a post with thousands of
      # direct replies must not put thousands of rows into one answer.
      for _ <- 1..3, do: reply_to(root, author)

      %{descendants: descendants} = Statuses.context(root, author, replies_limit: 2)

      assert length(descendants) == 2
    end

    test "does not walk a thread of unbounded depth", %{author: author} do
      # A peer can build a chain thousands deep. The answer is truncated
      # rather than refused: a reader wants the nearby conversation.
      chain =
        Enum.reduce(1..60, [status_fixture(%{account_id: author.id})], fn _, [parent | _] = acc ->
          [reply_to(parent, author) | acc]
        end)

      %{ancestors: ancestors} = Statuses.context(hd(chain), author)

      assert length(ancestors) <= Statuses.max_thread_depth()
    end
  end

  describe "pinning" do
    setup do
      author = account_fixture()

      %{author: author, status: status_fixture(%{account_id: author.id})}
    end

    test "puts a post at the top of a profile", %{author: author, status: status} do
      assert {:ok, _pin} = Statuses.pin(author, status)
      assert Enum.map(Statuses.pinned(author), & &1.id) == [status.id]
    end

    test "is idempotent, because a client retries", %{author: author, status: status} do
      {:ok, _} = Statuses.pin(author, status)

      assert {:ok, _} = Statuses.pin(author, status)
      assert length(Statuses.pinned(author)) == 1
    end

    test "refuses somebody else's post", %{status: status} do
      # A pin is a decoration on your own profile, not a way to put a stranger
      # on it.
      assert Statuses.pin(account_fixture(), status) == {:error, :not_yours}
    end

    test "refuses a post that is not public", %{author: author} do
      # Everybody who visits the profile sees a pin, so pinning a
      # followers-only post publishes it to people it was never addressed to.
      private = status_fixture(%{account_id: author.id, visibility: :private})

      assert Statuses.pin(author, private) == {:error, :not_public}
    end

    test "refuses a boost, which is not something to pin", %{author: author} do
      other = status_fixture(%{account_id: account_fixture().id})
      {:ok, boost} = Statuses.boost(author, other)

      assert Statuses.pin(author, boost) == {:error, :not_yours}
    end

    test "refuses a sixth pin, matching the profile it decorates", %{
      author: author,
      status: status
    } do
      for _ <- 1..Statuses.max_pins() do
        {:ok, _} = Statuses.pin(author, status_fixture(%{account_id: author.id}))
      end

      assert Statuses.pin(author, status) == {:error, :too_many}
      assert length(Statuses.pinned(author)) == Statuses.max_pins()
    end

    test "a deleted post frees its place on the board", %{author: author, status: status} do
      pinned =
        for _ <- 1..Statuses.max_pins() do
          post = status_fixture(%{account_id: author.id})
          {:ok, _} = Statuses.pin(author, post)
          post
        end

      {:ok, _} = Statuses.delete_status(hd(pinned))

      assert {:ok, _} = Statuses.pin(author, status)
    end

    test "unpinning takes it back off", %{author: author, status: status} do
      {:ok, _} = Statuses.pin(author, status)

      assert :ok = Statuses.unpin(author, status)
      assert Statuses.pinned(author) == []
    end

    test "unpinning what was never pinned is not an error", %{author: author, status: status} do
      assert :ok = Statuses.unpin(author, status)
    end
  end

  describe "boosting" do
    test "refuses somebody else's post that is not public" do
      # A boost of a followers-only post carries it to the booster's followers,
      # who are not the audience the author chose. Visible-to-me is not the
      # same permission as mine-to-republish.
      author = account_fixture()
      private = status_fixture(%{account_id: author.id, visibility: :private})

      refute Statuses.boostable?(account_fixture(), private)
    end

    test "allows your own, whatever its audience" do
      # Republishing your own post to your own followers reaches nobody it was
      # not already addressed to.
      author = account_fixture()
      private = status_fixture(%{account_id: author.id, visibility: :private})

      assert Statuses.boostable?(author, private)
    end

    test "allows anybody's public and unlisted posts" do
      author = account_fixture()

      for visibility <- [:public, :unlisted] do
        status = status_fixture(%{account_id: author.id, visibility: visibility})

        assert Statuses.boostable?(account_fixture(), status)
      end
    end
  end

  describe "muting a thread" do
    setup do
      author = account_fixture()
      conversation = conversation_fixture()
      status = status_fixture(%{account_id: author.id, conversation_id: conversation.id})

      %{author: author, status: status}
    end

    test "covers the replies nobody has written yet", %{author: author, status: status} do
      # Muting the status would only mute the past, which is the opposite of
      # what somebody muting a thread is asking for.
      reader = account_fixture()

      assert {:ok, _} = Statuses.mute_thread(reader, status)
      assert Statuses.thread_muted?(reader, status)

      later = status_fixture(%{account_id: author.id, conversation_id: status.conversation_id})

      assert Statuses.thread_muted?(reader, later)
    end

    test "is one person's decision, not everybody's", %{status: status} do
      reader = account_fixture()
      {:ok, _} = Statuses.mute_thread(reader, status)

      refute Statuses.thread_muted?(account_fixture(), status)
    end

    test "is idempotent", %{status: status} do
      reader = account_fixture()
      {:ok, _} = Statuses.mute_thread(reader, status)

      assert {:ok, _} = Statuses.mute_thread(reader, status)
    end

    test "unmuting brings the thread back", %{status: status} do
      reader = account_fixture()
      {:ok, _} = Statuses.mute_thread(reader, status)

      assert :ok = Statuses.unmute_thread(reader, status)
      refute Statuses.thread_muted?(reader, status)
    end

    test "a post in no conversation cannot be muted" do
      # Every post made here now starts a conversation (#221), so this state
      # has to be built by hand. The guard stays because the struct can still
      # reach it: a row written before that change and not yet backfilled, or
      # one built in memory.
      loose = %Status{id: 1, conversation_id: nil}

      assert Statuses.mute_thread(account_fixture(), loose) == {:error, :no_conversation}
      refute Statuses.thread_muted?(account_fixture(), loose)
    end
  end

  describe "publishing what was scheduled" do
    test "a poll whose expiry was stored as a string still publishes" do
      # The compose endpoint stores its params as they arrived, so a
      # form-encoded client's `expires_in` sat in the row as "3600" -- and
      # publication handed it straight to `DateTime.add/3`, which crashed the
      # worker. The worker publishes everything due in one run, so one
      # person's poll held up everybody's posts.
      author = account_fixture()

      {:ok, scheduled} =
        Statuses.schedule(
          author,
          %{
            "text" => "tea or coffee?",
            "poll" => %{"options" => ["tea", "coffee"], "expires_in" => "3600"}
          },
          DateTime.add(DateTime.utc_now(), 2, :hour)
        )

      assert {:ok, status} = Statuses.publish_scheduled(scheduled)

      poll = Statuses.get_poll(status)
      assert poll, "the poll was dropped instead of published"
      assert_in_delta DateTime.diff(poll.expires_at, DateTime.utc_now()), 3600, 60
    end

    test "and a stored expiry outside the bounds is clamped, not honoured" do
      # Scheduled polls never went through the clamp the immediate path has,
      # so a five-second poll or one expiring in the year 33715 published as
      # written.
      author = account_fixture()

      {:ok, scheduled} =
        Statuses.schedule(
          author,
          %{
            "text" => "quick one",
            "poll" => %{"options" => ["yes", "no"], "expires_in" => 5}
          },
          DateTime.add(DateTime.utc_now(), 2, :hour)
        )

      assert {:ok, status} = Statuses.publish_scheduled(scheduled)

      poll = Statuses.get_poll(status)

      assert_in_delta DateTime.diff(poll.expires_at, DateTime.utc_now()),
                      Poll.min_expiration_seconds(),
                      60
    end
  end

  describe "an idempotency key" do
    setup do
      author = account_fixture()

      %{author: author, status: status_fixture(%{account_id: author.id})}
    end

    test "hands back the post a retry already made", %{author: author, status: status} do
      # The client timed out and does not know the post landed. Answering with
      # the original is the difference between one post and two.
      :ok = Statuses.remember_key(author, "abc", status)

      assert %{id: id} = Statuses.replay_key(author, "abc")
      assert id == status.id
    end

    test "and the scheduled post a retry already made", %{author: author} do
      at = DateTime.add(DateTime.utc_now(), 2, :hour)
      {:ok, scheduled} = Statuses.schedule(author, %{"text" => "later"}, at)

      :ok = Statuses.remember_key(author, "sched", scheduled)

      assert %ScheduledStatus{id: id} = Statuses.replay_key(author, "sched")
      assert id == scheduled.id
    end

    test "which goes when the scheduled post does", %{author: author} do
      # Once it has gone out, the row the key names is deleted and the key goes
      # with it. A retry that late is a new post rather than an answer naming
      # something that no longer exists -- which is the only alternative, since
      # the published post is not what the key was recorded against.
      at = DateTime.add(DateTime.utc_now(), 2, :hour)
      {:ok, scheduled} = Statuses.schedule(author, %{"text" => "later"}, at)
      :ok = Statuses.remember_key(author, "sched", scheduled)

      Repo.delete!(scheduled)

      assert Statuses.replay_key(author, "sched") == nil
    end

    test "names one thing or the other, never neither", %{author: author} do
      # A key naming nothing would answer a retry with "you already did that"
      # and nothing to show for it.
      assert {:error, changeset} =
               %IdempotencyKey{}
               |> IdempotencyKey.changeset(%{
                 account_id: author.id,
                 key: "empty"
               })
               |> Repo.insert()

      assert %{status_id: [_]} = errors_on(changeset)
    end

    test "is nothing for a key nobody has used", %{author: author} do
      assert Statuses.replay_key(author, "never-seen") == nil
    end

    test "is one account's, not everybody's", %{author: author, status: status} do
      :ok = Statuses.remember_key(author, "abc", status)

      assert Statuses.replay_key(account_fixture(), "abc") == nil
    end

    test "is forgotten once it is older than a retry", %{author: author, status: status} do
      :ok = Statuses.remember_key(author, "abc", status)

      Abuuba.Repo.update_all(Abuuba.Statuses.IdempotencyKey,
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -2, :hour)]
      )

      assert Statuses.replay_key(author, "abc") == nil
    end

    test "sweeping removes the stale ones and keeps the fresh", %{author: author, status: status} do
      :ok = Statuses.remember_key(author, "old", status)

      Abuuba.Repo.update_all(Abuuba.Statuses.IdempotencyKey,
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -2, :hour)]
      )

      :ok = Statuses.remember_key(author, "new", status)

      assert {1, _} = Statuses.sweep_idempotency_keys()
      assert Statuses.replay_key(author, "new")
    end
  end
end
