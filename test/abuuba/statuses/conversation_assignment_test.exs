defmodule Abuuba.Statuses.ConversationAssignmentTest do
  @moduledoc """
  Every post belongs to a conversation.

  It is what a muted thread is muted by, so a post without one is a thread
  nobody can ever silence — which was true of every thread this server started.
  """

  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Statuses

  describe "a post made here" do
    test "starts a conversation of its own" do
      status = status_fixture(%{text: "on its own"})

      assert status.conversation_id
    end

    test "and two of them are two conversations" do
      one = status_fixture(%{text: "first"})
      other = status_fixture(%{text: "second"})

      refute one.conversation_id == other.conversation_id
    end
  end

  describe "a reply" do
    test "joins the conversation it is replying to" do
      root = status_fixture(%{text: "the start"})
      reply = status_fixture(%{text: "and on", in_reply_to_id: root.id})

      assert reply.conversation_id == root.conversation_id
    end

    test "however deep it is" do
      root = status_fixture(%{text: "the start"})
      middle = status_fixture(%{text: "middle", in_reply_to_id: root.id})
      deep = status_fixture(%{text: "deep", in_reply_to_id: middle.id})

      assert deep.conversation_id == root.conversation_id
    end

    test "and a caller that names one is believed" do
      # The federation path knows the conversation from the remote thread's URI
      # and passes it in. It must win over anything derived here.
      {:ok, conversation} = Statuses.upsert_conversation("https://far.example/thread/7")
      root = status_fixture(%{text: "the start"})

      reply =
        status_fixture(%{
          text: "and on",
          in_reply_to_id: root.id,
          conversation_id: conversation.id
        })

      assert reply.conversation_id == conversation.id
    end
  end

  describe "which is what makes muting work" do
    test "a thread started here can be muted" do
      # The whole point. This was `{:error, :no_conversation}` for every thread
      # this server started.
      root = status_fixture(%{text: "the start"})
      reply = status_fixture(%{text: "and on", in_reply_to_id: root.id})
      reader = account_fixture()

      assert {:ok, _mute} = Statuses.mute_thread(reader, reply)
      assert Statuses.thread_muted?(reader, reply)

      # And the root of the same thread, because they share the conversation.
      assert Statuses.thread_muted?(reader, root)
    end

    test "and muting one thread does not mute another" do
      first = status_fixture(%{text: "one"})
      second = status_fixture(%{text: "two"})
      reader = account_fixture()

      {:ok, _mute} = Statuses.mute_thread(reader, first)

      assert Statuses.thread_muted?(reader, first)
      refute Statuses.thread_muted?(reader, second)
    end
  end
end
