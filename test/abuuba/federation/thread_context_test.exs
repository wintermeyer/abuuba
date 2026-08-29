defmodule Abuuba.Federation.ThreadContextTest do
  @moduledoc """
  The identifier that holds a thread together across servers.

  Delivery is asynchronous and unordered, so a reply routinely arrives before
  the post it answers. Without a name for the conversation, the two halves get
  separate ones and never rejoin: the thread reads as two, and muting it
  silences one of them.
  """

  use Abuuba.DataCase, async: true

  import Abuuba.StatusesFixtures

  alias Abuuba.Federation.Serializer
  alias Abuuba.Federation.URIs
  alias Abuuba.Statuses

  describe "what a Note says about its thread" do
    test "a post carries the name of its conversation" do
      status = status_fixture(%{text: "the start"})

      assert %{"conversation" => uri} = Serializer.note(status)
      assert is_binary(uri)
    end

    test "and a reply carries the same one" do
      root = status_fixture(%{text: "the start"})
      reply = status_fixture(%{text: "and on", in_reply_to_id: root.id})

      assert Serializer.note(reply)["conversation"] == Serializer.note(root)["conversation"]
    end

    test "two threads do not share it" do
      one = status_fixture(%{text: "one"})
      other = status_fixture(%{text: "two"})

      refute Serializer.note(one)["conversation"] == Serializer.note(other)["conversation"]
    end

    test "a conversation that came from elsewhere keeps the name it arrived with" do
      # Echoing back what the originating server called it is what lets a
      # thread spanning three servers be one conversation on all of them.
      {:ok, conversation} = Statuses.upsert_conversation("https://far.example/contexts/7")
      status = status_fixture(%{text: "our reply", conversation_id: conversation.id})

      assert Serializer.note(status)["conversation"] == "https://far.example/contexts/7"
    end
  end

  describe "the name of a local conversation" do
    test "says which server it belongs to" do
      status = status_fixture(%{text: "hello"})
      uri = Serializer.note(status)["conversation"]

      assert uri =~ URIs.local_domain()
      assert uri =~ "objectType=Conversation"
    end

    test "and reading it back finds the same conversation" do
      # The round trip that matters: a peer replying to our thread quotes this
      # string back at us, and it has to mean the conversation it came from
      # rather than a new one.
      status = status_fixture(%{text: "hello"})
      uri = Serializer.note(status)["conversation"]

      assert {:ok, conversation} = Statuses.upsert_conversation(uri)
      assert conversation.id == status.conversation_id
    end
  end
end
