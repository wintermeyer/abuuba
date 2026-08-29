defmodule Abuuba.FeedsTest do
  use Abuuba.DataCase, async: true
  use Oban.Testing, repo: Abuuba.Repo

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Lists
  alias Abuuba.Relationships
  alias Abuuba.Statuses
  alias Abuuba.Timelines
  alias Abuuba.Timelines.FanOut
  alias Abuuba.Timelines.Feed

  setup do
    author = account_fixture()
    reader = account_fixture()
    {:ok, _} = Relationships.follow(reader, author)

    %{author: author, reader: reader}
  end

  defp home_ids(reader), do: reader |> Timelines.home() |> Enum.map(& &1.id)

  defp feed_rows(account, status) do
    %{rows: [[count]]} =
      Abuuba.Repo.query!(
        "SELECT count(*) FROM feed_entries WHERE feed_type = 'home' AND feed_id = $1 AND status_id = $2",
        [account.id, status.id]
      )

    count
  end

  describe "writing a post into feeds" do
    test "reaches the people who follow the author", %{author: author, reader: reader} do
      status = status_fixture(%{account_id: author.id, text: "hello"})

      assert home_ids(reader) == [status.id]
    end

    test "reaches nobody who does not follow them", %{author: author} do
      stranger = account_fixture()
      status_fixture(%{account_id: author.id, text: "hello"})

      assert home_ids(stranger) == []
    end

    test "the author sees their own post without waiting for anything", %{author: author} do
      # Inline, before any job is enqueued: a post that takes a second to
      # appear in your own timeline reads as a post that failed.
      status = status_fixture(%{account_id: author.id, text: "mine"})

      assert home_ids(author) == [status.id]
    end

    test "an author on another server gets no home feed of their own", %{reader: reader} do
      # A home feed is what somebody sees when they open this server as
      # themselves, and a remote account cannot do that. Writing one is a row
      # per remote post in the second-largest table that nobody will ever read.
      far = account_fixture(%{domain: "far.example", uri: "https://far.example/who"})
      {:ok, _follow} = Relationships.follow(reader, far)

      status = status_fixture(%{account_id: far.id, local: false, text: "from away"})

      assert feed_rows(far, status) == 0
      # The positive control: their followers here still get it, which is the
      # whole point of storing a remote post at all.
      assert status.id in home_ids(reader)
    end

    test "an author here still gets their own", %{author: author} do
      status = status_fixture(%{account_id: author.id, text: "mine"})

      assert feed_rows(author, status) == 1
    end

    test "one row per feed, however often the fan-out runs", %{author: author, reader: reader} do
      # An Oban job can run twice. The primary key is what makes that harmless.
      status = status_fixture(%{account_id: author.id, text: "hello"})

      FanOut.deliver(status)
      FanOut.deliver(status)

      assert home_ids(reader) == [status.id]
    end

    test "newest first", %{author: author, reader: reader} do
      older = status_fixture(%{account_id: author.id, text: "older"})
      newer = status_fixture(%{account_id: author.id, text: "newer"})

      assert home_ids(reader) == [newer.id, older.id]
    end
  end

  describe "who a post is kept from" do
    test "somebody who blocked the author", %{author: author, reader: reader} do
      {:ok, _} = Relationships.block(reader, author)
      status_fixture(%{account_id: author.id, text: "hello"})

      assert home_ids(reader) == []
    end

    test "somebody the author blocked", %{author: author, reader: reader} do
      {:ok, _} = Relationships.block(author, reader)
      status_fixture(%{account_id: author.id, text: "hello"})

      assert home_ids(reader) == []
    end

    test "somebody who muted the author", %{author: author, reader: reader} do
      {:ok, _} = Relationships.mute(reader, author)
      status_fixture(%{account_id: author.id, text: "hello"})

      assert home_ids(reader) == []
    end

    test "somebody who blocked the author's whole server", %{reader: reader} do
      remote = remote_account_fixture(%{domain: "remote.example"})
      {:ok, _} = Relationships.follow(reader, remote)
      {:ok, _} = Relationships.block_domain(reader, "remote.example")

      status_fixture(%{
        account_id: remote.id,
        text: "hello",
        local: false,
        uri: "https://r.test/1"
      })

      assert home_ids(reader) == []
    end

    test "somebody who put the author in an exclusive list", %{author: author, reader: reader} do
      # An exclusive list takes its members out of the home feed, which is what
      # makes a list a way of reading less.
      {:ok, list} = Lists.create(reader, %{title: "Quiet", exclusive: true})
      :ok = Lists.add(list, [author.id])

      status_fixture(%{account_id: author.id, text: "hello"})

      assert home_ids(reader) == []
    end
  end

  describe "replies" do
    test "a reply reaches somebody who follows both people", %{author: author, reader: reader} do
      other = account_fixture()
      {:ok, _} = Relationships.follow(reader, other)

      parent = status_fixture(%{account_id: other.id, text: "the question"})

      reply =
        status_fixture(%{
          account_id: author.id,
          text: "the answer",
          in_reply_to_id: parent.id,
          in_reply_to_account_id: other.id
        })

      assert reply.id in home_ids(reader)
    end

    test "a reply to a stranger does not", %{author: author, reader: reader} do
      # Otherwise following one person fills your timeline with half of
      # conversations you cannot see the other side of.
      other = account_fixture()
      parent = status_fixture(%{account_id: other.id, text: "the question"})

      reply =
        status_fixture(%{
          account_id: author.id,
          text: "the answer",
          in_reply_to_id: parent.id,
          in_reply_to_account_id: other.id
        })

      refute reply.id in home_ids(reader)
    end

    test "somebody replying to themselves still reaches their followers", %{
      author: author,
      reader: reader
    } do
      first = status_fixture(%{account_id: author.id, text: "one"})

      second =
        status_fixture(%{
          account_id: author.id,
          text: "two",
          in_reply_to_id: first.id,
          in_reply_to_account_id: author.id
        })

      assert second.id in home_ids(reader)
    end

    test "a reply to the reader reaches them", %{author: author, reader: reader} do
      parent = status_fixture(%{account_id: reader.id, text: "mine"})

      reply =
        status_fixture(%{
          account_id: author.id,
          text: "answering you",
          in_reply_to_id: parent.id,
          in_reply_to_account_id: reader.id
        })

      assert reply.id in home_ids(reader)
    end
  end

  describe "what a follow can ask for" do
    test "boosts can be turned off per person", %{author: author, reader: reader} do
      {:ok, _} = Relationships.follow(reader, author, %{show_reblogs: false})

      original = status_fixture(%{account_id: account_fixture().id, text: "somebody else's"})
      {:ok, boost} = Statuses.boost(author, original)

      refute boost.id in home_ids(reader)
    end

    test "boosts are on unless somebody says otherwise", %{author: author, reader: reader} do
      original = status_fixture(%{account_id: account_fixture().id, text: "somebody else's"})
      {:ok, boost} = Statuses.boost(author, original)

      assert boost.id in home_ids(reader)
    end

    test "a language filter narrows what arrives", %{author: author, reader: reader} do
      {:ok, _} = Relationships.follow(reader, author, %{languages: ["en"]})

      german = status_fixture(%{account_id: author.id, text: "guten Tag", language: "de"})
      english = status_fixture(%{account_id: author.id, text: "hello", language: "en"})

      ids = home_ids(reader)

      assert english.id in ids
      refute german.id in ids
    end

    test "a post with no language set still arrives", %{author: author, reader: reader} do
      # Most posts carry no language. Filtering them out would empty the
      # timeline of somebody who set a filter meaning "not the other one".
      {:ok, _} = Relationships.follow(reader, author, %{languages: ["en"]})

      status = status_fixture(%{account_id: author.id, text: "hello", language: nil})

      assert status.id in home_ids(reader)
    end
  end

  describe "lists" do
    test "a member's post reaches the list feed", %{author: author, reader: reader} do
      {:ok, list} = Lists.create(reader, %{title: "Friends"})
      :ok = Lists.add(list, [author.id])

      status = status_fixture(%{account_id: author.id, text: "hello"})

      assert Enum.map(Timelines.list(list, reader), & &1.id) == [status.id]
    end

    test "a reply stays out of a list that asked for none", %{author: author, reader: reader} do
      # Lists are the tool for reading less, and the first thing somebody does
      # with a noisy one is turn replies off. The field was stored, importable
      # and documented, and nothing applied it -- so doing that changed
      # nothing.
      {:ok, list} = Lists.create(reader, %{title: "Quiet", replies_policy: "none"})
      :ok = Lists.add(list, [author.id])

      other = account_fixture()
      parent = status_fixture(%{account_id: other.id, text: "a question"})
      status_fixture(%{account_id: author.id, text: "an answer", in_reply_to_id: parent.id})

      post = status_fixture(%{account_id: author.id, text: "a post of their own"})

      assert Enum.map(Timelines.list(list, reader), & &1.id) == [post.id]
    end

    test "the default keeps replies to other members", %{author: author, reader: reader} do
      {:ok, list} = Lists.create(reader, %{title: "Friends"})
      member = account_fixture()
      {:ok, _follow} = Relationships.follow(reader, member)
      :ok = Lists.add(list, [author.id, member.id])

      parent = status_fixture(%{account_id: member.id, text: "a question"})
      reply = status_fixture(%{account_id: author.id, in_reply_to_id: parent.id})

      assert reply.id in Enum.map(Timelines.list(list, reader), & &1.id)
    end

    test "and the backlog a new member brings in obeys it too", %{
      author: author,
      reader: reader
    } do
      other = account_fixture()
      parent = status_fixture(%{account_id: other.id, text: "a question"})
      status_fixture(%{account_id: author.id, text: "an answer", in_reply_to_id: parent.id})
      post = status_fixture(%{account_id: author.id, text: "a post of their own"})

      {:ok, list} = Lists.create(reader, %{title: "Quiet", replies_policy: "none"})
      :ok = Lists.add(list, [author.id])

      assert Enum.map(Timelines.list(list, reader), & &1.id) == [post.id]
    end

    test "and drops replies to everybody else", %{author: author, reader: reader} do
      {:ok, list} = Lists.create(reader, %{title: "Friends"})
      :ok = Lists.add(list, [author.id])

      stranger = account_fixture()
      parent = status_fixture(%{account_id: stranger.id, text: "a question"})
      reply = status_fixture(%{account_id: author.id, in_reply_to_id: parent.id})

      refute reply.id in Enum.map(Timelines.list(list, reader), & &1.id)
    end

    test "and followed keeps replies to anybody the owner follows", %{
      author: author,
      reader: reader
    } do
      {:ok, list} = Lists.create(reader, %{title: "Wide", replies_policy: "followed"})
      :ok = Lists.add(list, [author.id])

      known = account_fixture()
      {:ok, _follow} = Relationships.follow(reader, known)

      parent = status_fixture(%{account_id: known.id, text: "a question"})
      reply = status_fixture(%{account_id: author.id, in_reply_to_id: parent.id})

      assert reply.id in Enum.map(Timelines.list(list, reader), & &1.id)
    end

    test "somebody else's post does not", %{reader: reader} do
      {:ok, list} = Lists.create(reader, %{title: "Friends"})
      stranger = account_fixture()
      {:ok, _} = Relationships.follow(reader, stranger)

      status_fixture(%{account_id: stranger.id, text: "hello"})

      assert Timelines.list(list, reader) == []
    end
  end

  describe "taking things back out" do
    test "deleting a post clears it from every feed it reached", %{
      author: author,
      reader: reader
    } do
      status = status_fixture(%{account_id: author.id, text: "hello"})
      assert home_ids(reader) == [status.id]

      {:ok, _} = Statuses.delete_status(status)

      assert home_ids(reader) == []
    end

    test "unfollowing clears what that person put there", %{author: author, reader: reader} do
      status_fixture(%{account_id: author.id, text: "hello"})

      :ok = Relationships.unfollow(reader, author)

      assert home_ids(reader) == []
    end

    test "blocking clears them out too", %{author: author, reader: reader} do
      status_fixture(%{account_id: author.id, text: "hello"})

      {:ok, _} = Relationships.block(reader, author)

      assert home_ids(reader) == []
    end
  end

  describe "the cap" do
    test "a feed is trimmed to its limit", %{author: author, reader: reader} do
      # Enforced periodically rather than on every insert: trimming on write
      # turns one insert into an insert and a delete, on the hottest path there
      # is.
      for n <- 1..(Feed.limit() + 5) do
        Feed.insert("home", reader.id, author.id + n)
      end

      assert Feed.count("home", reader.id) > Feed.limit()

      Feed.trim("home", reader.id)

      assert Feed.count("home", reader.id) == Feed.limit()
    end

    test "trimming keeps the newest", %{reader: reader} do
      for n <- 1..(Feed.limit() + 3), do: Feed.insert("home", reader.id, n)

      Feed.trim("home", reader.id)

      assert Feed.newest("home", reader.id) == Feed.limit() + 3
    end
  end

  describe "the sweeper" do
    test "trims the feeds that are over, and leaves the rest alone", %{reader: reader} do
      other = account_fixture()

      for n <- 1..(Feed.limit() + 4), do: Feed.insert("home", reader.id, n)
      Feed.insert("home", other.id, 1)

      assert :ok = perform_job(Abuuba.Timelines.MaintenanceWorker, %{})

      assert Feed.count("home", reader.id) == Feed.limit()
      assert Feed.count("home", other.id) == 1
    end
  end

  describe "fanning out at scale" do
    test "does the first chunk now and queues the rest", %{author: author} do
      # Everything inline would make posting take as long as the audience is
      # large; everything queued would make a post to three people wait on the
      # queue. The first chunk is the one the author is waiting on.
      for _ <- 1..(FanOut.chunk_size() + 2) do
        follower = account_fixture()
        {:ok, _} = Relationships.follow(follower, author)
      end

      status = status_fixture(%{account_id: author.id, text: "to a crowd"})

      assert [job] = all_enqueued(worker: FanOut)
      assert job.args["status_id"] == status.id
      # Whatever did not fit in the first chunk, and no more.
      assert length(job.args["accounts"]) < FanOut.chunk_size()
    end

    test "queues nothing at all for a small audience", %{author: author} do
      status_fixture(%{account_id: author.id, text: "to a few"})

      assert all_enqueued(worker: FanOut) == []
    end

    test "a queued chunk writes the same rows the inline one would", %{author: author} do
      for _ <- 1..(FanOut.chunk_size() + 1) do
        follower = account_fixture()
        {:ok, _} = Relationships.follow(follower, author)
      end

      status = status_fixture(%{account_id: author.id, text: "to a crowd"})

      assert [job] = all_enqueued(worker: FanOut)
      assert :ok = perform_job(FanOut, job.args)

      for late <- job.args["accounts"] do
        assert status.id in Feed.status_ids("home", late, %{})
      end
    end

    test "splits a big audience into chunks rather than one job each", %{author: author} do
      # One job per follower is the model this is deliberately not: twenty
      # thousand followers should be forty jobs, not twenty thousand.
      assert FanOut.chunk_size() >= 100

      followers =
        for _ <- 1..3 do
          follower = account_fixture()
          {:ok, _} = Relationships.follow(follower, author)
          follower
        end

      status = status_fixture(%{account_id: author.id, text: "hello"})

      for follower <- followers do
        assert status.id in home_ids(follower)
      end
    end

    test "leaves out somebody who has not signed in for a long time", %{author: author} do
      # A feed written for somebody who has not opened the place in a year is
      # rows nobody reads, paid for on every post.
      dormant = account_fixture()
      {:ok, _} = Relationships.follow(dormant, author)

      user =
        user_fixture(%{
          account_id: dormant.id,
          approved: true,
          confirmed_at: DateTime.utc_now()
        })

      {:ok, _} =
        user
        |> Ecto.Changeset.change(last_signed_in_at: DateTime.add(DateTime.utc_now(), -365, :day))
        |> Abuuba.Repo.update()

      status_fixture(%{account_id: author.id, text: "hello"})

      assert home_ids(dormant) == []
    end

    test "somebody with no account here is not dormant, they are remote", %{author: author} do
      # A remote follower has no user row and never signs in. Treating that as
      # dormant would stop every post to every other server.
      remote = remote_account_fixture(%{domain: "remote.example"})
      {:ok, _} = Relationships.follow(remote, author)

      status = status_fixture(%{account_id: author.id, text: "hello"})

      assert status.id in Feed.status_ids("home", remote.id, %{})
    end
  end
end
