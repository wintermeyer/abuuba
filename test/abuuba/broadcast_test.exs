defmodule Abuuba.BroadcastTest do
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Statuses
  alias Abuuba.Streaming
  alias Abuuba.Timelines.Broadcast

  setup do
    author = account_fixture()
    reader = account_fixture()
    status = status_fixture(%{account_id: author.id, text: "something happened"})

    on_exit(fn -> Broadcast.forget(status) end)

    %{author: author, reader: reader, status: status}
  end

  describe "counting who is listening" do
    test "a topic nobody is on has nobody on it" do
      refute Broadcast.listening?("streaming:test:#{System.unique_integer([:positive])}")
    end

    test "subscribing puts somebody on it" do
      topic = "streaming:test:#{System.unique_integer([:positive])}"

      :ok = Broadcast.subscribe(topic)

      assert Broadcast.listening?(topic)
      assert Broadcast.listener_count(topic) == 1
    end

    test "unsubscribing takes them off again" do
      topic = "streaming:test:#{System.unique_integer([:positive])}"
      :ok = Broadcast.subscribe(topic)

      :ok = Broadcast.unsubscribe(topic)

      refute Broadcast.listening?(topic)
    end

    test "a socket that dies without saying so is noticed" do
      # Which is most of them. A count that only goes up makes every topic
      # look busy forever, and the whole point is skipping the quiet ones.
      topic = "streaming:test:#{System.unique_integer([:positive])}"

      {pid, ref} = spawn_monitor(fn -> Broadcast.subscribe(topic) end)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1000 -> flunk("the subscriber never finished")
      end

      # The monitor is the broadcaster's, so give it a moment to be handled.
      Process.sleep(50)

      refute Broadcast.listening?(topic)
    end

    test "two subscribers are two, and one leaving leaves one" do
      topic = "streaming:test:#{System.unique_integer([:positive])}"
      me = self()

      :ok = Broadcast.subscribe(topic)

      other =
        spawn(fn ->
          Broadcast.subscribe(topic)
          send(me, :subscribed)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :subscribed

      assert Broadcast.listener_count(topic) == 2

      send(other, :stop)
      Process.sleep(50)

      assert Broadcast.listener_count(topic) == 1
    end
  end

  describe "publishing" do
    test "reaches somebody who is listening", %{status: status} do
      topic = "streaming:test:#{System.unique_integer([:positive])}"
      :ok = Broadcast.subscribe(topic)

      :ok = Broadcast.publish(topic, "update", status)

      assert_receive {:streaming, "update", _payload}
    end

    test "does nothing at all for a topic nobody is on", %{status: status} do
      # The saving is not the message, it is everything the publisher would
      # have done to prepare one.
      topic = "streaming:test:#{System.unique_integer([:positive])}"

      assert Broadcast.publish(topic, "update", status) == :ok
      refute_receive {:streaming, _event, _payload}, 50
    end
  end

  describe "rendering once" do
    test "gives a signed-out reader the payload with no reader fields", %{status: status} do
      payload = Broadcast.render(status, nil)

      assert payload["id"] == to_string(status.id)
      assert payload["content"] =~ "something happened"
    end

    test "patches what only one reader can answer", %{status: status, reader: reader} do
      {:ok, _} = Statuses.favourite(reader, status)

      payload = Broadcast.render(status, reader)

      assert payload["favourited"]
      refute payload["bookmarked"]
    end

    test "two readers get two answers from one render", %{status: status, reader: reader} do
      other = account_fixture()
      {:ok, _} = Statuses.favourite(reader, status)

      mine = Broadcast.render(status, reader)
      theirs = Broadcast.render(status, other)

      assert mine["favourited"]
      refute theirs["favourited"]
      assert mine["content"] == theirs["content"]
    end

    test "in one query, however many readers and whichever marks they made", %{
      status: status,
      reader: reader
    } do
      # Five queries ran per socket per arriving post, so a post reaching a
      # hundred sockets asked five hundred questions to fill in five booleans
      # each. Counted rather than asserted about, because this is the whole
      # point of the change and nothing else would notice it going back.
      other = account_fixture()
      {:ok, _} = Statuses.favourite(reader, status)
      {:ok, _} = Statuses.bookmark(reader, status)
      {:ok, _} = Statuses.boost(other, status)

      {:ok, counter} = Agent.start_link(fn -> 0 end)
      handler = "reader-state-#{System.unique_integer([:positive])}"

      # Detached when the test ends, or it keeps firing for the rest of the
      # suite and dies against an agent that is gone.
      on_exit(fn -> :telemetry.detach(handler) end)

      :telemetry.attach(
        handler,
        [:abuuba, :repo, :query],
        fn _event, _measure, _meta, _config -> Agent.update(counter, &(&1 + 1)) end,
        nil
      )

      state = Statuses.reader_state(status, [reader.id, other.id])

      assert Agent.get(counter, & &1) == 1

      assert state[reader.id]["favourited"]
      assert state[reader.id]["bookmarked"]
      refute state[reader.id]["reblogged"]
      assert state[other.id]["reblogged"]
      refute state[other.id]["favourited"]
    end

    test "a muted conversation is one of the five it answers", %{reader: reader} do
      # The fifth branch of the union, and the one that is left out when a
      # post has no conversation -- a branch matching nothing costs a scan.
      conversation = conversation_fixture()
      author = account_fixture()

      status =
        status_fixture(%{account_id: author.id, conversation_id: conversation.id})

      refute Statuses.reader_state(status, [reader.id])[reader.id]["muted"]

      {:ok, _} = Statuses.mute_thread(reader, status)

      assert Statuses.reader_state(status, [reader.id])[reader.id]["muted"]
    end

    test "answers for many readers at once", %{status: status, reader: reader} do
      other = account_fixture()
      {:ok, _} = Statuses.favourite(reader, status)

      answers = Broadcast.render_many(status, [reader, other])

      assert answers[reader.id]["favourited"]
      refute answers[other.id]["favourited"]
    end

    test "an edited post is rendered again rather than served from before", %{status: status} do
      # A cached payload that outlived the words it describes is the reader
      # being shown something that is no longer true.
      Broadcast.render(status, nil)

      {:ok, edited} = Statuses.edit_status(status, %{"text" => "something else happened"})

      assert Broadcast.render(edited, nil)["content"] =~ "something else"
    end

    test "a deleted post is forgotten", %{status: status} do
      Broadcast.render(status, nil)

      {:ok, _} = Statuses.delete_status(status)

      # Nothing asserts on the payload here: what matters is that the next
      # render asks the database rather than handing back the old entry.
      assert Broadcast.render(status.id, nil) == nil
    end
  end

  describe "the streaming layer on top" do
    test "publishes a post to the author's own topic", %{author: author} do
      :ok = Streaming.subscribe(Streaming.account_topic(author))

      status_fixture(%{account_id: author.id, text: "for my own stream"})

      assert_receive {:streaming, "update", _status}
    end

    test "says when a post has changed", %{author: author, status: status} do
      :ok = Streaming.subscribe(Streaming.account_topic(author))

      {:ok, _} = Statuses.edit_status(status, %{"text" => "reworded"})

      assert_receive {:streaming, "status.update", _status}
    end
  end
end
