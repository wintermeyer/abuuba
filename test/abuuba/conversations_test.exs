defmodule Abuuba.ConversationsTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Conversations
  alias Abuuba.Relationships
  alias Abuuba.Statuses
  alias Abuuba.Timelines
  alias Abuuba.Timelines.Feed

  setup do
    alice = account_fixture()
    bob = account_fixture()

    %{alice: alice, bob: bob}
  end

  defp direct(from, to, text, opts \\ []) do
    {:ok, conversation} = Statuses.upsert_conversation(nil)

    {:ok, status} =
      Statuses.create_status(
        Enum.into(opts, %{
          account_id: from.id,
          text: "@#{to.username} #{text}",
          visibility: :direct,
          conversation_id: conversation.id
        })
      )

    status
  end

  defp reply(from, to, parent, text) do
    {:ok, status} =
      Statuses.create_status(%{
        account_id: from.id,
        text: "@#{to.username} #{text}",
        visibility: :direct,
        conversation_id: parent.conversation_id,
        in_reply_to_id: parent.id,
        in_reply_to_account_id: parent.account_id
      })

    status
  end

  describe "an inbox" do
    test "has a row for the sender and one for whoever was written to", %{
      alice: alice,
      bob: bob
    } do
      direct(alice, bob, "hello")

      assert [_alice_row] = Conversations.list(alice)
      assert [_bob_row] = Conversations.list(bob)
    end

    test "has nothing for somebody who was not in it", %{alice: alice, bob: bob} do
      stranger = account_fixture()
      direct(alice, bob, "hello")

      assert Conversations.list(stranger) == []
    end

    test "is one line per thread, not one per message", %{alice: alice, bob: bob} do
      # Twenty messages back and forth is one conversation somebody is having.
      first = direct(alice, bob, "hello")
      reply(bob, alice, first, "hello yourself")
      reply(alice, bob, first, "how are you")

      assert [row] = Conversations.list(alice)
      assert length(row.status_ids) == 3
    end

    test "the last message is the newest one", %{alice: alice, bob: bob} do
      first = direct(alice, bob, "hello")
      last = reply(bob, alice, first, "hello yourself")

      assert [row] = Conversations.list(alice)
      assert row.last_status_id == last.id
    end

    test "min_id pages forward from the near end", %{alice: alice, bob: bob} do
      carol = account_fixture()
      dave = account_fixture()

      oldest = direct(alice, bob, "one")
      middle = direct(alice, carol, "two")
      _newest = direct(alice, dave, "three")

      assert [row] = Conversations.list(alice, %{min_id: oldest.id, limit: 1})
      assert row.last_status_id == middle.id
    end

    test "newest thread first", %{alice: alice, bob: bob} do
      carol = account_fixture()

      older = direct(alice, bob, "the older thread")
      _newer = direct(alice, carol, "the newer thread")

      assert [first, second] = Conversations.list(alice)
      assert second.last_status_id == older.id
      assert first.last_status_id != older.id
    end

    test "seeks by cursor", %{alice: alice, bob: bob} do
      carol = account_fixture()
      older = direct(alice, bob, "older")
      newer = direct(alice, carol, "newer")

      assert [row] = Conversations.list(alice, %{max_id: newer.id})
      assert row.last_status_id == older.id
    end

    test "a group message is its own thread, not the two-person one", %{
      alice: alice,
      bob: bob
    } do
      # The same conversation with a different set of people in it is a
      # different thread to whoever is reading it.
      carol = account_fixture()

      {:ok, conversation} = Statuses.upsert_conversation(nil)

      {:ok, _} =
        Statuses.create_status(%{
          account_id: alice.id,
          text: "@#{bob.username} just you",
          visibility: :direct,
          conversation_id: conversation.id
        })

      {:ok, _} =
        Statuses.create_status(%{
          account_id: alice.id,
          text: "@#{bob.username} @#{carol.username} all of you",
          visibility: :direct,
          conversation_id: conversation.id
        })

      assert length(Conversations.list(alice)) == 2
    end
  end

  describe "unread" do
    test "a message arriving is unread for whoever it was sent to", %{alice: alice, bob: bob} do
      direct(alice, bob, "hello")

      assert [row] = Conversations.list(bob)
      assert row.unread
    end

    test "and read for the person who sent it", %{alice: alice, bob: bob} do
      # Nobody needs telling about their own message.
      direct(alice, bob, "hello")

      assert [row] = Conversations.list(alice)
      refute row.unread
    end

    test "can be marked read", %{alice: alice, bob: bob} do
      direct(alice, bob, "hello")
      [row] = Conversations.list(bob)

      assert {:ok, _} = Conversations.mark_read(bob, row.id)
      assert [%{unread: false}] = Conversations.list(bob)
    end

    test "can be marked unread again", %{alice: alice, bob: bob} do
      direct(alice, bob, "hello")
      [row] = Conversations.list(bob)
      {:ok, _} = Conversations.mark_read(bob, row.id)

      assert {:ok, _} = Conversations.mark_unread(bob, row.id)
      assert [%{unread: true}] = Conversations.list(bob)
    end

    test "a new message makes a read thread unread again", %{alice: alice, bob: bob} do
      first = direct(alice, bob, "hello")
      [row] = Conversations.list(bob)
      {:ok, _} = Conversations.mark_read(bob, row.id)

      reply(alice, bob, first, "still there?")

      assert [%{unread: true}] = Conversations.list(bob)
    end

    test "counts what is waiting", %{alice: alice, bob: bob} do
      carol = account_fixture()
      direct(alice, bob, "hello")
      direct(carol, bob, "hello too")

      assert Conversations.unread_count(bob) == 2
    end

    test "will not touch somebody else's row", %{alice: alice, bob: bob} do
      direct(alice, bob, "hello")
      [bobs] = Conversations.list(bob)

      assert Conversations.mark_read(alice, bobs.id) == {:error, :not_found}
      assert [%{unread: true}] = Conversations.list(bob)
    end
  end

  describe "muting and removing" do
    test "a muted thread stops being counted", %{alice: alice, bob: bob} do
      direct(alice, bob, "hello")
      [row] = Conversations.list(bob)

      assert {:ok, _} = Conversations.mute(bob, row.id)
      assert Conversations.unread_count(bob) == 0
    end

    test "a muted thread is still there to read", %{alice: alice, bob: bob} do
      # Muting is about not being told, not about hiding what was said.
      direct(alice, bob, "hello")
      [row] = Conversations.list(bob)
      {:ok, _} = Conversations.mute(bob, row.id)

      assert [%{muted: true}] = Conversations.list(bob)
    end

    test "removing takes it out of one inbox only", %{alice: alice, bob: bob} do
      # Deleting a conversation is a local decision. Reaching into somebody
      # else's inbox is not something a message you received lets you do.
      direct(alice, bob, "hello")
      [row] = Conversations.list(bob)

      assert :ok = Conversations.remove(bob, row.id)

      assert Conversations.list(bob) == []
      assert [_still_there] = Conversations.list(alice)
    end

    test "a new message brings a removed thread back", %{alice: alice, bob: bob} do
      first = direct(alice, bob, "hello")
      [row] = Conversations.list(bob)
      :ok = Conversations.remove(bob, row.id)

      reply(alice, bob, first, "are you there")

      assert [_back] = Conversations.list(bob)
    end
  end

  describe "deleting a message" do
    test "takes it out of the inbox", %{alice: alice, bob: bob} do
      status = direct(alice, bob, "just this one")

      assert [_row] = Conversations.list(bob)

      {:ok, _} = Statuses.delete_status(status)

      assert Conversations.list(bob) == []
      assert Conversations.list(alice) == []
    end

    test "and promotes the one before it when there is one", %{alice: alice, bob: bob} do
      first = direct(alice, bob, "the first")
      second = reply(bob, alice, first, "the second")

      assert [row] = Conversations.list(alice)
      assert row.last_status_id == second.id

      {:ok, _} = Statuses.delete_status(second)

      assert [row] = Conversations.list(alice)
      assert row.last_status_id == first.id
      refute second.id in row.status_ids
    end

    test "and leaves an unread count that can still be cleared", %{alice: alice, bob: bob} do
      first = direct(alice, bob, "the first")
      second = reply(alice, bob, first, "the second")

      assert Conversations.unread_count(bob) == 1

      {:ok, _} = Statuses.delete_status(second)

      # Still one waiting -- the first message is unread and still there. The
      # point is that it is not counting a post nobody can open.
      assert Conversations.unread_count(bob) == 1
      assert [row] = Conversations.list(bob)
      assert row.last_status_id == first.id
    end

    test "but not somebody else's conversation", %{alice: alice, bob: bob} do
      # The control: a delete must reach the rows that name the post and no
      # others, and a version that emptied the table would pass the tests
      # above.
      carol = account_fixture()
      theirs = direct(bob, carol, "not about this")
      mine = direct(alice, bob, "about this")

      {:ok, _} = Statuses.delete_status(mine)

      assert [row] = Conversations.list(carol)
      assert row.last_status_id == theirs.id
    end
  end

  describe "keeping direct messages out of everything else" do
    test "a direct message is not in a follower's home feed", %{alice: alice, bob: bob} do
      # Following somebody does not mean reading their private messages to
      # other people.
      follower = account_fixture()
      {:ok, _} = Relationships.follow(follower, alice)

      status = direct(alice, bob, "not for you")

      refute status.id in Feed.status_ids("home", follower.id, %{limit: 50})
    end

    test "it is not in the public timeline", %{alice: alice, bob: bob} do
      status = direct(alice, bob, "not for anybody")

      refute status.id in Enum.map(Timelines.public(nil), & &1.id)
    end

    test "the sender still has it in their own feed", %{alice: alice, bob: bob} do
      # Somebody's own messages belong in their own timeline; that is where a
      # client shows what they just sent.
      status = direct(alice, bob, "mine")

      assert status.id in Feed.status_ids("home", alice.id, %{limit: 50})
    end
  end

  describe "delivering twice" do
    test "is delivering once", %{alice: alice, bob: bob} do
      # An Oban job can run twice, and two messages can arrive at the same
      # moment. Neither may produce a second inbox row.
      status = direct(alice, bob, "hello")

      Conversations.deliver(status)
      Conversations.deliver(status)

      assert [row] = Conversations.list(bob)
      assert length(row.status_ids) == 1
    end
  end
end
