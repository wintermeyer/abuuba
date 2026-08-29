defmodule Abuuba.StreamingTest do
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Conversations
  alias Abuuba.Filters
  alias Abuuba.Notifications
  alias Abuuba.Relationships
  alias Abuuba.Statuses
  alias Abuuba.Streaming
  alias AbuubaWeb.Streaming.Filter

  setup do
    %{author: account_fixture(), reader: account_fixture()}
  end

  defp socket(account, streams) do
    topics =
      Enum.map(streams, fn
        {stream, topic} -> {stream, topic}
        stream -> {stream, Streaming.public_topic()}
      end)

    %{account: account, scopes: ["read"], topics: MapSet.new(topics)}
  end

  describe "what is published" do
    test "a public post reaches the public topic", %{author: author} do
      :ok = Streaming.subscribe(Streaming.public_topic())

      status = status_fixture(%{account_id: author.id})

      assert_receive {:streaming, "update", %{id: id}}
      assert id == status.id
    end

    test "a followers-only post never reaches a public topic", %{author: author} do
      # Publishing it and relying on the per-socket filter to hold it back
      # would put it one bug away from a stranger.
      :ok = Streaming.subscribe(Streaming.public_topic())

      status_fixture(%{account_id: author.id, visibility: :private})

      refute_receive {:streaming, "update", _status}, 100
    end

    test "every post reaches its author's own topic", %{author: author} do
      :ok = Streaming.subscribe(Streaming.account_topic(author))

      status_fixture(%{account_id: author.id, visibility: :direct})

      assert_receive {:streaming, "update", _status}
    end

    test "a hashtag topic gets posts carrying it", %{author: author} do
      :ok = Streaming.subscribe(Streaming.hashtag_topic("cycling"))

      status = status_fixture(%{account_id: author.id})
      :ok = Statuses.tag_status(status, tag_fixture("cycling"))

      # Published on create, before the tag existed, so the second publish is
      # what a tagged post looks like once its tags are attached.
      Streaming.publish_status(Repo.reload(status))

      assert_receive {:streaming, "update", _status}
    end

    test "a delete is announced too", %{author: author} do
      status = status_fixture(%{account_id: author.id})
      :ok = Streaming.subscribe(Streaming.public_topic())

      {:ok, _} = Statuses.delete_status(status)

      assert_receive {:streaming, "delete", %{id: id}}
      assert id == status.id
    end

    test "a notification reaches the person it is about", %{author: author, reader: reader} do
      :ok = Streaming.subscribe(Streaming.account_topic(reader))

      {:ok, _} = Notifications.notify(reader, author, "follow")

      assert_receive {:streaming, "notification", _notification}
    end

    test "a filtered notification is not pushed", %{author: author, reader: reader} do
      # It belongs in the requests inbox, and pushing it would put it in front
      # of somebody who asked for it not to be.
      {:ok, _} = Notifications.put_policy(reader, %{"for_not_following" => "filter"})
      :ok = Streaming.subscribe(Streaming.account_topic(reader))

      {:ok, _} = Notifications.notify(reader, author, "mention")

      refute_receive {:streaming, "notification", _notification}, 100
    end
  end

  describe "who is shown what" do
    test "an anonymous socket sees a public post", %{author: author} do
      status = status_fixture(%{account_id: author.id})

      assert {:ok, frame} = Filter.for_viewer("update", status, socket(nil, ["public"]))
      assert frame =~ ~s("event":"update")
    end

    test "an anonymous socket never sees a followers-only post", %{author: author} do
      status = status_fixture(%{account_id: author.id, visibility: :private})

      assert Filter.for_viewer("update", status, socket(nil, ["public"])) == :skip
    end

    test "a reader does not see somebody they blocked", %{author: author, reader: reader} do
      status = status_fixture(%{account_id: author.id})
      {:ok, _} = Relationships.block(reader, author)

      assert Filter.for_viewer("update", status, socket(reader, ["public"])) == :skip
    end

    test "a reader does not see somebody who blocked them", %{author: author, reader: reader} do
      status = status_fixture(%{account_id: author.id})
      {:ok, _} = Relationships.block(author, reader)

      assert Filter.for_viewer("update", status, socket(reader, ["public"])) == :skip
    end

    test "a reader does not see a boost of somebody they blocked", %{
      author: author,
      reader: reader
    } do
      # Blocking somebody has to survive a third party repeating them, or the
      # block is only as good as nobody boosting. The timelines check the
      # boosted author; this stream only ever looked at whoever pressed the
      # button.
      booster = account_fixture()
      original = status_fixture(%{account_id: author.id})
      {:ok, _} = Relationships.block(reader, author)
      {:ok, boost} = Statuses.boost(booster, original)

      assert Filter.for_viewer("update", boost, socket(reader, ["public"])) == :skip
    end

    test "and a boost of somebody they muted is the same", %{author: author, reader: reader} do
      booster = account_fixture()
      original = status_fixture(%{account_id: author.id})
      {:ok, _} = Relationships.mute(reader, author, %{})
      {:ok, boost} = Statuses.boost(booster, original)

      assert Filter.for_viewer("update", boost, socket(reader, ["public"])) == :skip
    end

    test "but an ordinary boost still arrives", %{author: author, reader: reader} do
      # The control: dropping every boost would satisfy both tests above.
      booster = account_fixture()
      original = status_fixture(%{account_id: author.id})
      {:ok, boost} = Statuses.boost(booster, original)

      assert {:ok, _frame} = Filter.for_viewer("update", boost, socket(reader, ["public"]))
    end

    test "a reader does not see a server they shut out", %{reader: reader} do
      # Blocking a domain is blocking everybody on it. The timelines learned
      # that; this stream had not, so a reader who had shut a whole server out
      # still watched it arrive live.
      stranger = account_fixture(%{domain: "shut-out.example"})
      status = status_fixture(%{account_id: stranger.id})

      {:ok, _} = Relationships.block_domain(reader, "shut-out.example")

      assert Filter.for_viewer("update", status, socket(reader, ["public"])) == :skip
    end

    test "and still sees a server they did not", %{reader: reader} do
      # The control. Skipping everything remote would satisfy the test above on
      # its own.
      neighbour = account_fixture(%{domain: "welcome.example"})
      status = status_fixture(%{account_id: neighbour.id})

      {:ok, _} = Relationships.block_domain(reader, "shut-out.example")

      assert {:ok, _frame} = Filter.for_viewer("update", status, socket(reader, ["public"]))
    end

    test "a reader does not see somebody they muted", %{author: author, reader: reader} do
      status = status_fixture(%{account_id: author.id})
      {:ok, _} = Relationships.mute(reader, author, %{})

      assert Filter.for_viewer("update", status, socket(reader, ["public"])) == :skip
    end

    test "a reader does not see a thread they muted", %{author: author, reader: reader} do
      conversation = conversation_fixture()
      status = status_fixture(%{account_id: author.id, conversation_id: conversation.id})
      {:ok, _} = Statuses.mute_thread(reader, status)

      assert Filter.for_viewer("update", status, socket(reader, ["public"])) == :skip
    end

    test "a direct message goes on the direct stream and not the user one", %{
      author: author,
      reader: reader
    } do
      status = status_fixture(%{account_id: author.id, visibility: :direct})
      {:ok, _} = Statuses.mention(status, reader)

      assert {:ok, frame} = Filter.for_viewer("update", status, socket(reader, ["direct"]))
      assert frame =~ ~s("stream":["direct"])

      assert Filter.for_viewer("update", status, socket(reader, ["user"])) == :skip
    end

    test "and the inbox row goes with it, which is what a messages column reads", %{
      author: author,
      reader: reader
    } do
      status = status_fixture(%{account_id: author.id, visibility: :direct, text: "just us"})
      {:ok, _} = Statuses.mention(status, reader)
      :ok = Conversations.deliver(Abuuba.Repo.reload!(status))

      [row] = Conversations.list(reader)

      assert {:ok, frame} = Filter.for_viewer("conversation", row, socket(reader, ["direct"]))
      assert frame =~ ~s("event":"conversation")
      assert frame =~ ~s("stream":["direct"])
      # The entity a client expects, rather than the post on its own.
      assert frame =~ "unread"
      assert frame =~ "last_status"
    end

    test "and a socket that did not ask for its messages is not sent one", %{
      author: author,
      reader: reader
    } do
      status = status_fixture(%{account_id: author.id, visibility: :direct})
      {:ok, _} = Statuses.mention(status, reader)
      :ok = Conversations.deliver(Abuuba.Repo.reload!(status))
      [row] = Conversations.list(reader)

      # The positive control is the test above: the same row, the same reader,
      # a socket that did ask.
      assert Filter.for_viewer("conversation", row, socket(reader, ["user"])) == :skip
      assert Filter.for_viewer("conversation", row, socket(nil, ["direct"])) == :skip
    end

    test "a media stream carries only posts with something attached", %{author: author} do
      plain = status_fixture(%{account_id: author.id})
      with_media = status_fixture(%{account_id: author.id, ordered_media_attachment_ids: [1]})

      assert Filter.for_viewer("update", plain, socket(nil, ["public:media"])) == :skip
      assert {:ok, _} = Filter.for_viewer("update", with_media, socket(nil, ["public:media"]))
    end

    test "a local stream carries only what was written here", %{author: author} do
      remote = remote_account_fixture(%{username: "bob", domain: "remote.example"})

      there =
        status_fixture(%{account_id: remote.id, local: false, uri: "https://remote.example/s/1"})

      here = status_fixture(%{account_id: author.id, local: true})

      assert Filter.for_viewer("update", there, socket(nil, ["public:local"])) == :skip
      assert {:ok, _} = Filter.for_viewer("update", here, socket(nil, ["public:local"]))
    end

    test "one post can name several streams it belongs on", %{author: author} do
      # A client is told all of them so it can put the post in each list it is
      # showing.
      status = status_fixture(%{account_id: author.id, local: true})

      assert {:ok, frame} =
               Filter.for_viewer("update", status, socket(nil, ["public", "public:local"]))

      assert frame =~ "public"
      assert frame =~ "public:local"
    end

    test "a notification for somebody else is never pushed", %{author: author, reader: reader} do
      {:ok, notification} = Notifications.notify(reader, author, "follow")

      assert Filter.for_viewer(
               "notification",
               notification,
               socket(author, ["user:notification"])
             ) == :skip
    end
  end

  describe "a filter somebody just changed" do
    test "is announced to their own stream", %{reader: reader} do
      # A client applies filters itself against the rules it fetched when it
      # connected. Without this it goes on hiding by the old ones until it
      # reconnects, so a word somebody adds keeps appearing in the timeline
      # they are watching -- and one they remove stays hidden.
      :ok = Streaming.subscribe(Streaming.account_topic(reader))

      {:ok, filter} =
        Filters.create(reader, %{
          "title" => "Spoilers",
          "context" => ["home"],
          "keywords_attributes" => [%{"keyword" => "ending"}]
        })

      assert_receive {:streaming, "filters_changed", _payload}

      {:ok, _} = Filters.update(filter, %{"title" => "Spoilers, please"})
      assert_receive {:streaming, "filters_changed", _payload}

      {:ok, _} = Filters.delete(filter)
      assert_receive {:streaming, "filters_changed", _payload}
    end

    test "and reaches nobody else", %{author: author, reader: reader} do
      :ok = Streaming.subscribe(Streaming.account_topic(author))

      {:ok, _} =
        Filters.create(reader, %{"title" => "Mine", "context" => ["home"]})

      refute_receive {:streaming, "filters_changed", _payload}
    end

    test "and a socket on the user stream is handed it", %{reader: reader} do
      state = socket(reader, [{"user", Streaming.account_topic(reader)}])

      assert {:ok, frame} = Filter.for_viewer("filters_changed", nil, state)
      assert %{"stream" => ["user"], "event" => "filters_changed"} = Jason.decode!(frame)
    end

    test "and a socket watching only the public stream is not", %{reader: reader} do
      state = socket(reader, ["public"])

      assert Filter.for_viewer("filters_changed", nil, state) == :skip
    end
  end

  describe "an announcement" do
    test "reaches a socket watching its own stream", %{reader: reader} do
      # It is published on a topic and was then dropped by every socket: there
      # was no clause for it in the per-socket filter, so the two ends each
      # looked right and had never been put together. A server notice that
      # nobody watching a timeline is shown is a server notice that does not
      # work.
      state = socket(reader, [{"user", Streaming.account_topic(reader)}])

      {:ok, announcement} =
        Abuuba.Instance.create_announcement(%{text: "The server moves on Sunday."})

      assert {:ok, frame} = Filter.for_viewer("announcement", announcement, state)
      decoded = Jason.decode!(frame)

      assert %{"stream" => ["user"], "event" => "announcement"} = decoded
      assert Jason.decode!(decoded["payload"])["content"] =~ "moves on Sunday"
    end

    test "and says so when it is taken down", %{reader: reader} do
      state = socket(reader, [{"user", Streaming.account_topic(reader)}])

      assert {:ok, frame} = Filter.for_viewer("announcement.delete", %{id: 7}, state)
      decoded = Jason.decode!(frame)

      assert decoded["event"] == "announcement.delete"
      # An id, as a string, which is all a client needs to take the notice off
      # the screen.
      assert decoded["payload"] == "7"
    end

    test "and the tally under it moves for everybody", %{reader: reader, author: author} do
      # Two people reacting to the same notice each saw only their own, because
      # nothing said the count had changed.
      :ok = Streaming.subscribe(Streaming.announcement_topic())

      {:ok, announcement} = Abuuba.Instance.create_announcement(%{text: "Party on Friday."})

      :ok = Abuuba.Instance.react_to_announcement(announcement, reader, "🎉")
      assert_receive {:streaming, "announcement.reaction", %{name: "🎉", count: 1}}

      :ok = Abuuba.Instance.react_to_announcement(announcement, author, "🎉")
      assert_receive {:streaming, "announcement.reaction", %{name: "🎉", count: 2}}

      # Taking one back says so too, or a client is left showing a tally
      # nobody stands behind.
      :ok = Abuuba.Instance.unreact_to_announcement(announcement, author, "🎉")
      assert_receive {:streaming, "announcement.reaction", %{name: "🎉", count: 1}}
    end

    test "and a socket is handed the new count", %{reader: reader} do
      state = socket(reader, [{"user", Streaming.account_topic(reader)}])
      reaction = %{announcement_id: 7, name: "🎉", count: 3}

      assert {:ok, frame} = Filter.for_viewer("announcement.reaction", reaction, state)
      decoded = Jason.decode!(frame)

      assert decoded["event"] == "announcement.reaction"

      assert Jason.decode!(decoded["payload"]) == %{
               "announcement_id" => "7",
               "name" => "🎉",
               "count" => 3
             }
    end

    test "and a stranger watching the public stream is not sent one", %{reader: reader} do
      # The reference implementation publishes these per account, so a socket
      # with no account never sees them.
      state = %{socket(reader, ["public"]) | account: nil}

      {:ok, announcement} = Abuuba.Instance.create_announcement(%{text: "Notice."})

      assert Filter.for_viewer("announcement", announcement, state) == :skip
    end
  end

  describe "the envelope" do
    test "carries the payload as a string, which is what clients parse twice",
         %{author: author} do
      # Sending an object instead makes every existing client fail on the
      # second parse.
      status = status_fixture(%{account_id: author.id})

      {:ok, frame} = Filter.for_viewer("update", status, socket(nil, ["public"]))
      decoded = Jason.decode!(frame)

      assert is_binary(decoded["payload"])
      assert Jason.decode!(decoded["payload"])["content"]
    end

    test "a delete carries only an id", %{author: author} do
      status = status_fixture(%{account_id: author.id})

      {:ok, frame} = Filter.for_viewer("delete", status, socket(nil, ["public"]))

      assert Jason.decode!(frame)["payload"] == to_string(status.id)
    end
  end

  describe "a token that has been revoked" do
    test "tells the connections holding it to close" do
      # The socket authenticates once, at connect, and a live stream can
      # outlive the decision to revoke by hours. "Sign out everywhere" has to
      # mean the stream too, or it does not mean everywhere.
      token_id = System.unique_integer([:positive])

      :ok = Streaming.subscribe(Streaming.token_topic(token_id))
      :ok = Streaming.revoked(token_id)

      assert_receive {:streaming, :revoked}
    end

    test "and says nothing to a connection holding a different one" do
      # The control: a broadcast that reached everybody would close every
      # stream on the server, which is a worse bug than the one being fixed.
      mine = System.unique_integer([:positive])
      theirs = System.unique_integer([:positive])

      :ok = Streaming.subscribe(Streaming.token_topic(mine))
      :ok = Streaming.revoked(theirs)

      refute_receive {:streaming, :revoked}, 100
    end
  end
end
