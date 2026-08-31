defmodule Abuuba.TimelinesTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Relationships
  alias Abuuba.Statuses
  alias Abuuba.Timelines

  setup do
    %{reader: account_fixture(), author: account_fixture()}
  end

  describe "the home timeline" do
    test "carries what the people you follow said", %{reader: reader, author: author} do
      {:ok, _} = Relationships.follow(reader, author)
      status = status_fixture(%{account_id: author.id})

      assert Enum.map(Timelines.home(reader), & &1.id) == [status.id]
    end

    test "drops what somebody said before you muted them", %{reader: reader, author: author} do
      # A mute is read at the moment the timeline is drawn rather than written
      # into the feed, so it reaches backwards: what is already there goes too.
      # That is what people expect of a mute and it is what the code does; the
      # user guide claimed the opposite until this test was written.
      {:ok, _} = Relationships.follow(reader, author)
      status = status_fixture(%{account_id: author.id})

      assert Enum.map(Timelines.home(reader), & &1.id) == [status.id]

      {:ok, _} = Relationships.mute(reader, author, %{})

      assert Timelines.home(reader) == []
    end

    test "and brings it back when the mute is lifted", %{reader: reader, author: author} do
      # The other half of reading it at draw time: nothing was deleted, so
      # undoing the mute restores the timeline rather than leaving a hole.
      {:ok, _} = Relationships.follow(reader, author)
      status = status_fixture(%{account_id: author.id})
      {:ok, _} = Relationships.mute(reader, author, %{})

      assert Timelines.home(reader) == []

      :ok = Relationships.unmute(reader, author)

      assert Enum.map(Timelines.home(reader), & &1.id) == [status.id]
    end

    test "carries your own, because a timeline that hides your post reads as a failure",
         %{reader: reader} do
      own = status_fixture(%{account_id: reader.id})

      assert Enum.map(Timelines.home(reader), & &1.id) == [own.id]
    end

    test "carries nothing from a stranger", %{reader: reader, author: author} do
      status_fixture(%{account_id: author.id})

      assert Timelines.home(reader) == []
    end

    test "carries a followers-only post from somebody you follow", %{
      reader: reader,
      author: author
    } do
      {:ok, _} = Relationships.follow(reader, author)
      status = status_fixture(%{account_id: author.id, visibility: :private})

      assert Enum.map(Timelines.home(reader), & &1.id) == [status.id]
    end

    test "leaves out somebody you blocked", %{reader: reader, author: author} do
      {:ok, _} = Relationships.follow(reader, author)
      status_fixture(%{account_id: author.id})
      {:ok, _} = Relationships.block(reader, author)

      assert Timelines.home(reader) == []
    end

    test "leaves out somebody who blocked you", %{reader: reader, author: author} do
      {:ok, _} = Relationships.follow(reader, author)
      status_fixture(%{account_id: author.id})
      {:ok, _} = Relationships.block(author, reader)

      assert Timelines.home(reader) == []
    end

    test "leaves out somebody you muted, until the mute runs out", %{
      reader: reader,
      author: author
    } do
      {:ok, _} = Relationships.follow(reader, author)
      status_fixture(%{account_id: author.id})

      {:ok, _} =
        Relationships.mute(reader, author, %{
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert Timelines.home(reader) == []

      Relationships.unmute(reader, author)

      assert length(Timelines.home(reader)) == 1
    end

    test "leaves out a boost of somebody you blocked", %{reader: reader, author: author} do
      # A block is about the person, not about who passed their post along. The
      # filter matched the boost row's own author -- the booster -- so blocking
      # somebody still let their words through inside anybody else's boost,
      # which is the one hole a person notices at once.
      {:ok, _} = Relationships.follow(reader, author)

      blocked = account_fixture()
      theirs = status_fixture(%{account_id: blocked.id})
      {:ok, _} = Relationships.block(reader, blocked)

      status_fixture(%{account_id: author.id, reblog_of_id: theirs.id, text: ""})
      ordinary = status_fixture(%{account_id: author.id})

      ids = Enum.map(Timelines.home(reader), & &1.id)

      # The control: what the author wrote themselves is still there.
      assert ordinary.id in ids
      assert length(ids) == 1, "a boost of a blocked account reached the home timeline"
    end

    test "leaves out a thread you muted", %{reader: reader, author: author} do
      {:ok, _} = Relationships.follow(reader, author)
      conversation = conversation_fixture()
      status = status_fixture(%{account_id: author.id, conversation_id: conversation.id})

      {:ok, _} = Statuses.mute_thread(reader, status)

      assert Timelines.home(reader) == []
    end

    test "leaves out what was deleted", %{reader: reader, author: author} do
      {:ok, _} = Relationships.follow(reader, author)
      status = status_fixture(%{account_id: author.id})
      {:ok, _} = Statuses.delete_status(status)

      assert Timelines.home(reader) == []
    end
  end

  describe "the public timeline" do
    test "carries public posts and nothing quieter", %{author: author} do
      public = status_fixture(%{account_id: author.id, visibility: :public})

      for visibility <- [:unlisted, :private, :direct] do
        status_fixture(%{account_id: author.id, visibility: visibility})
      end

      assert Enum.map(Timelines.public(nil), & &1.id) == [public.id]
    end

    test "leaves out a domain the reader blocked", %{author: author} do
      # Blocking a domain is blocking everybody on it. The fan-out already
      # keeps their posts out of a home feed, but the public and hashtag
      # timelines are live queries with no feed in front of them, so a reader
      # who had shut out a whole server still met it there.
      reader = account_fixture()
      shouty = remote_account_fixture(%{username: "loud", domain: "spam.example"})
      quiet = remote_account_fixture(%{username: "fine", domain: "ok.example"})

      {:ok, _} = Relationships.block_domain(reader, "spam.example")

      status_fixture(%{account_id: shouty.id, local: false, uri: "https://spam.example/s/1"})

      wanted =
        status_fixture(%{account_id: quiet.id, local: false, uri: "https://ok.example/s/1"})

      mine = status_fixture(%{account_id: author.id})

      shown = Enum.map(Timelines.public(reader), & &1.id)

      # The positive control rides along: the rest of the timeline is intact,
      # so this is a filter rather than an empty answer.
      assert wanted.id in shown
      assert mine.id in shown
      assert length(shown) == 2
    end

    test "can be asked for only what was written here", %{author: author} do
      here = status_fixture(%{account_id: author.id, local: true})
      remote = remote_account_fixture(%{username: "bob", domain: "remote.example"})

      status_fixture(%{
        account_id: remote.id,
        local: false,
        uri: "https://remote.example/s/1"
      })

      assert Enum.map(Timelines.public(nil, %{local: true}), & &1.id) == [here.id]
    end

    test "can be asked for only what came from elsewhere", %{author: author} do
      status_fixture(%{account_id: author.id, local: true})
      remote = remote_account_fixture(%{username: "bob", domain: "remote.example"})

      there =
        status_fixture(%{account_id: remote.id, local: false, uri: "https://remote.example/s/1"})

      assert Enum.map(Timelines.public(nil, %{remote: true}), & &1.id) == [there.id]
    end

    test "can be asked for only posts carrying something", %{author: author} do
      status_fixture(%{account_id: author.id})

      with_media =
        status_fixture(%{account_id: author.id, ordered_media_attachment_ids: [1, 2]})

      assert Enum.map(Timelines.public(nil, %{only_media: true}), & &1.id) == [with_media.id]
    end

    test "leaves out somebody the reader blocked", %{reader: reader, author: author} do
      status_fixture(%{account_id: author.id})
      {:ok, _} = Relationships.block(reader, author)

      assert Timelines.public(reader) == []
      assert length(Timelines.public(nil)) == 1
    end

    test "leaves out what silenced and suspended accounts wrote", %{author: author} do
      # A silence is a moderator saying "not in front of strangers", and the
      # public timeline is the largest room of strangers there is.
      visible = status_fixture(%{account_id: author.id})

      silenced = account_fixture()
      status_fixture(%{account_id: silenced.id})

      {:ok, _} =
        Abuuba.Accounts.update_moderation(silenced, %{silenced_at: DateTime.utc_now()})

      assert Enum.map(Timelines.public(nil), & &1.id) == [visible.id]
    end

    test "and by_ids/2 drops them too, because a ranking is never revisited",
         %{author: author} do
      # `Timelines.by_ids/2` reads what a ranking chose, and a ranking is
      # written once: a moderator silencing somebody afterwards does not take
      # their post out of it. Without this the most prominent list on the
      # server was the one place a silence did not reach.
      visible = status_fixture(%{account_id: author.id})

      silenced = account_fixture()
      hidden = status_fixture(%{account_id: silenced.id})

      {:ok, _} =
        Abuuba.Accounts.update_moderation(silenced, %{silenced_at: DateTime.utc_now()})

      ids = [to_string(hidden.id), to_string(visible.id)]

      assert Enum.map(Timelines.by_ids(ids, nil), & &1.id) == [visible.id]
    end

    test "and the reader's own blocks, which a ranking knows nothing about",
         %{author: author} do
      reader = account_fixture()
      mine = status_fixture(%{account_id: author.id})

      unwanted_author = account_fixture()
      unwanted = status_fixture(%{account_id: unwanted_author.id})
      {:ok, _} = Abuuba.Relationships.block(reader, unwanted_author)

      ids = [to_string(unwanted.id), to_string(mine.id)]

      assert Enum.map(Timelines.by_ids(ids, reader), & &1.id) == [mine.id]
      assert Enum.map(Timelines.by_ids(ids, nil), & &1.id) == [unwanted.id, mine.id]
    end

    test "min_id wins over since_id when both arrive", %{author: author} do
      first = status_fixture(%{account_id: author.id})
      second = status_fixture(%{account_id: author.id})
      third = status_fixture(%{account_id: author.id})

      # A client that sends both means the min_id window; honouring since_id
      # as a second bound would skip the middle of the gap being filled.
      ids =
        Timelines.public(nil, %{min_id: first.id, since_id: second.id, limit: 1})
        |> Enum.map(& &1.id)

      assert ids == [second.id]
      refute third.id in ids
    end

    test "leaves out boosts", %{reader: reader, author: author} do
      # A boost carries somebody to their followers. The public timeline is
      # everybody, who saw the original when it was written.
      original = status_fixture(%{account_id: author.id})
      {:ok, _} = Statuses.boost(reader, original)

      assert Enum.map(Timelines.public(nil), & &1.id) == [original.id]
    end

    test "leaves out replies, but keeps a thread somebody spins themselves", %{
      reader: reader,
      author: author
    } do
      post = status_fixture(%{account_id: author.id})

      own_thread =
        status_fixture(%{
          account_id: author.id,
          in_reply_to_id: post.id,
          in_reply_to_account_id: author.id
        })

      status_fixture(%{
        account_id: reader.id,
        in_reply_to_id: post.id,
        in_reply_to_account_id: author.id
      })

      assert Enum.map(Timelines.public(nil), & &1.id) == [own_thread.id, post.id]
    end
  end

  describe "a hashtag timeline" do
    setup %{author: author} do
      cats = tag_fixture("cats")
      dogs = tag_fixture("dogs")

      %{cats: cats, dogs: dogs, author: author}
    end

    defp tagged(author, tags, attrs \\ %{}) do
      status = status_fixture(Map.merge(%{account_id: author.id}, attrs))
      for tag <- tags, do: :ok = Statuses.tag_status(status, tag)

      status
    end

    test "carries posts under the tag", %{author: author, cats: cats} do
      status = tagged(author, [cats])
      status_fixture(%{account_id: author.id})

      assert Enum.map(Timelines.tag("cats", nil), & &1.id) == [status.id]
    end

    test "does not mind how the tag was capitalised", %{author: author, cats: cats} do
      status = tagged(author, [cats])

      assert Enum.map(Timelines.tag("Cats", nil), & &1.id) == [status.id]
      assert Enum.map(Timelines.tag("#cats", nil), & &1.id) == [status.id]
    end

    test "`any` widens", %{author: author, cats: cats, dogs: dogs} do
      one = tagged(author, [cats])
      two = tagged(author, [dogs])

      ids = Timelines.tag("cats", nil, %{any: ["dogs"]}) |> Enum.map(& &1.id) |> Enum.sort()

      assert ids == Enum.sort([one.id, two.id])
    end

    test "`all` narrows", %{author: author, cats: cats, dogs: dogs} do
      tagged(author, [cats])
      both = tagged(author, [cats, dogs])

      assert Enum.map(Timelines.tag("cats", nil, %{all: ["dogs"]}), & &1.id) == [both.id]
    end

    test "`none` excludes", %{author: author, cats: cats, dogs: dogs} do
      only_cats = tagged(author, [cats])
      tagged(author, [cats, dogs])

      assert Enum.map(Timelines.tag("cats", nil, %{none: ["dogs"]}), & &1.id) == [only_cats.id]
    end

    test "carries unlisted posts, which a public timeline does not", %{
      author: author,
      cats: cats
    } do
      # Unlisted means "not in the firehose". Somebody who typed a hashtag has
      # asked for exactly this, so a tag timeline is where it belongs.
      status = tagged(author, [cats], %{visibility: :unlisted})

      assert Enum.map(Timelines.tag("cats", nil), & &1.id) == [status.id]
      assert Timelines.public(nil) == []
    end

    test "and drops a silenced author, the way the public timeline does", %{cats: cats} do
      quiet = account_fixture()
      loud = account_fixture()
      kept = tagged(loud, [cats])
      tagged(quiet, [cats])

      assert length(Timelines.tag("cats", nil)) == 2

      {:ok, _} = Accounts.update_moderation(quiet, %{silenced_at: DateTime.utc_now()})

      assert Enum.map(Timelines.tag("cats", nil), & &1.id) == [kept.id]
    end

    test "and a suspended one", %{cats: cats} do
      gone = account_fixture()
      tagged(gone, [cats])

      assert length(Timelines.tag("cats", nil)) == 1

      {:ok, _} = Accounts.update_moderation(gone, %{suspended_at: DateTime.utc_now()})

      assert Timelines.tag("cats", nil) == []
    end

    test "carries nothing for a tag nobody used" do
      assert Timelines.tag("nothing-here", nil) == []
    end
  end

  describe "paging" do
    test "walks backwards from a cursor", %{reader: reader} do
      ids = for _ <- 1..5, do: status_fixture(%{account_id: reader.id}).id
      [_oldest, second | _] = Enum.sort(ids)

      page = Timelines.home(reader, %{max_id: second, limit: 10})

      assert Enum.map(page, & &1.id) == [Enum.min(ids)]
    end

    test "reads forwards for min_id and still renders newest first", %{reader: reader} do
      # The ascending window is what a client catching up asks for; the list it
      # renders still reads top to bottom.
      ids = Enum.sort(for(_ <- 1..5, do: status_fixture(%{account_id: reader.id}).id))
      [oldest | rest] = ids

      page = Timelines.home(reader, %{min_id: oldest, order: :asc, limit: 2})

      assert Enum.map(page, & &1.id) == rest |> Enum.take(2) |> Enum.reverse()
    end

    test "honours the limit", %{reader: reader} do
      for _ <- 1..5, do: status_fixture(%{account_id: reader.id})

      assert length(Timelines.home(reader, %{limit: 2})) == 2
    end
  end

  describe "read markers" do
    test "remember where somebody was", %{reader: reader} do
      {:ok, marker} = Timelines.put_marker(reader, "home", 123)

      assert marker.last_read_id == 123
      assert marker.version == 1
      assert %{"home" => %{last_read_id: 123}} = Timelines.markers(reader, ["home"])
    end

    test "move forwards and count up", %{reader: reader} do
      {:ok, _} = Timelines.put_marker(reader, "home", 123)
      {:ok, moved} = Timelines.put_marker(reader, "home", 456)

      assert moved.last_read_id == 456
      assert moved.version == 2
    end

    test "refuse a write against a stale version", %{reader: reader} do
      # Two clients both holding a marker is the ordinary case. Last write wins
      # would drag somebody's place back to whatever the slower device thought.
      {:ok, _} = Timelines.put_marker(reader, "home", 123)
      {:ok, _} = Timelines.put_marker(reader, "home", 456)

      assert Timelines.put_marker(reader, "home", 200, 1) == {:error, :conflict}
    end

    test "accept a write naming the version it holds", %{reader: reader} do
      {:ok, first} = Timelines.put_marker(reader, "home", 123)

      assert {:ok, _} = Timelines.put_marker(reader, "home", 456, first.version)
    end

    test "are one account's and one timeline's", %{reader: reader} do
      {:ok, _} = Timelines.put_marker(reader, "home", 123)
      {:ok, _} = Timelines.put_marker(reader, "notifications", 999)

      assert %{"home" => home, "notifications" => notifications} =
               Timelines.markers(reader, ["home", "notifications"])

      assert home.last_read_id == 123
      assert notifications.last_read_id == 999
      assert Timelines.markers(account_fixture(), ["home"]) == %{}
    end

    test "refuse a timeline nobody keeps a marker for", %{reader: reader} do
      assert {:error, changeset} = Timelines.put_marker(reader, "invented", 1)
      assert %{timeline: [_]} = errors_on(changeset)
    end
  end
end
