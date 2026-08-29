defmodule Abuuba.FeedMergeTest do
  use Abuuba.DataCase, async: true
  use Oban.Testing, repo: Abuuba.Repo

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Lists
  alias Abuuba.Relationships
  alias Abuuba.Statuses
  alias Abuuba.Timelines
  alias Abuuba.Timelines.Feed

  setup do
    %{author: account_fixture(), reader: account_fixture()}
  end

  defp home_ids(reader), do: Feed.status_ids("home", reader.id, %{limit: 100})

  describe "following somebody" do
    test "brings what they already said into the feed", %{author: author, reader: reader} do
      # Following and then seeing nothing until they post again is a follow
      # that looks broken.
      old = status_fixture(%{account_id: author.id, text: "said before you followed"})

      {:ok, _} = Relationships.follow(reader, author)

      assert old.id in home_ids(reader)
    end

    test "brings what a follower may now read, including followers-only posts", %{
      author: author,
      reader: reader
    } do
      # The same rule their profile uses. Inventing a second visibility rule
      # for the feed would mean a post somebody can read on the profile and
      # cannot read in the timeline, which is the confusing half of both.
      quiet = status_fixture(%{account_id: author.id, text: "quiet", visibility: :private})

      {:ok, _} = Relationships.follow(reader, author)

      assert quiet.id in home_ids(reader)
    end

    test "brings nothing addressed to somebody else", %{author: author, reader: reader} do
      direct =
        status_fixture(%{account_id: author.id, text: "for one person", visibility: :direct})

      {:ok, _} = Relationships.follow(reader, author)

      refute direct.id in home_ids(reader)
    end

    test "brings a bounded number, not everything they ever wrote", %{
      author: author,
      reader: reader
    } do
      for n <- 1..10, do: status_fixture(%{account_id: author.id, text: "post #{n}"})

      {:ok, _} = Relationships.follow(reader, author)

      assert length(home_ids(reader)) <= Timelines.backfill_limit()
    end

    test "respects a boost preference set at the same time", %{author: author, reader: reader} do
      original = status_fixture(%{account_id: account_fixture().id, text: "somebody else's"})
      {:ok, boost} = Statuses.boost(author, original)

      {:ok, _} = Relationships.follow(reader, author, %{show_reblogs: false})

      refute boost.id in home_ids(reader)
    end

    test "brings nothing from somebody they have blocked", %{author: author, reader: reader} do
      status_fixture(%{account_id: author.id, text: "hello"})
      {:ok, _} = Relationships.block(reader, author)

      Timelines.merge_account(reader, author)

      assert home_ids(reader) == []
    end
  end

  describe "unfollowing somebody" do
    setup %{author: author, reader: reader} do
      {:ok, _} = Relationships.follow(reader, author)

      :ok
    end

    test "takes their posts back out", %{author: author, reader: reader} do
      status_fixture(%{account_id: author.id, text: "hello"})

      :ok = Relationships.unfollow(reader, author)

      assert home_ids(reader) == []
    end

    test "leaves a friend's boost of them alone", %{author: author, reader: reader} do
      # Unfollowing says "I do not subscribe to you". A boost by somebody the
      # reader does follow is that person's boost, and blocking is the thing
      # that says otherwise.
      other = account_fixture()
      {:ok, _} = Relationships.follow(reader, other)

      theirs = status_fixture(%{account_id: author.id, text: "the original"})
      {:ok, boost} = Statuses.boost(other, theirs)

      :ok = Relationships.unfollow(reader, author)

      assert boost.id in home_ids(reader)
    end

    test "leaves a post still reachable through a followed hashtag", %{
      author: author,
      reader: reader
    } do
      {:ok, tag} = Statuses.upsert_tag("gardening")
      :ok = Statuses.follow_tag(reader, tag)

      status = status_fixture(%{account_id: author.id, text: "about #gardening"})

      :ok = Relationships.unfollow(reader, author)

      assert status.id in home_ids(reader)
    end
  end

  describe "blocking and muting" do
    setup %{author: author, reader: reader} do
      {:ok, _} = Relationships.follow(reader, author)

      :ok
    end

    test "blocking clears their posts", %{author: author, reader: reader} do
      status_fixture(%{account_id: author.id, text: "hello"})

      {:ok, _} = Relationships.block(reader, author)

      assert home_ids(reader) == []
    end

    test "blocking clears a friend's boost of them", %{author: author, reader: reader} do
      # Blocking says "I do not want to see you", which is harsher than
      # unfollowing on purpose.
      other = account_fixture()
      {:ok, _} = Relationships.follow(reader, other)

      theirs = status_fixture(%{account_id: author.id, text: "the original"})
      {:ok, boost} = Statuses.boost(other, theirs)

      {:ok, _} = Relationships.block(reader, author)

      refute boost.id in home_ids(reader)
    end

    test "blocking clears posts that mention them", %{author: author, reader: reader} do
      # A block means not seeing them, and a post naming them carries their
      # handle into the timeline.
      other = account_fixture(%{username: "mentioner#{System.unique_integer([:positive])}"})
      {:ok, _} = Relationships.follow(reader, other)

      mention =
        status_fixture(%{account_id: other.id, text: "talking about @#{author.username}"})

      Statuses.link_text(mention)

      {:ok, _} = Relationships.block(reader, author)

      refute mention.id in home_ids(reader)
    end

    test "muting clears their posts too", %{author: author, reader: reader} do
      status_fixture(%{account_id: author.id, text: "hello"})

      {:ok, _} = Relationships.mute(reader, author)

      assert home_ids(reader) == []
    end

    test "unmuting brings the person back for new posts", %{author: author, reader: reader} do
      {:ok, _} = Relationships.mute(reader, author)
      :ok = Relationships.unmute(reader, author)

      status = status_fixture(%{account_id: author.id, text: "after"})

      assert status.id in home_ids(reader)
    end
  end

  describe "hashtags" do
    test "following one brings its recent posts in", %{author: author, reader: reader} do
      status = status_fixture(%{account_id: author.id, text: "about #gardening"})
      {:ok, tag} = Statuses.upsert_tag("gardening")

      :ok = Statuses.follow_tag(reader, tag)

      assert status.id in home_ids(reader)
    end

    test "a new post under a followed tag arrives", %{author: author, reader: reader} do
      {:ok, tag} = Statuses.upsert_tag("gardening")
      :ok = Statuses.follow_tag(reader, tag)

      status = status_fixture(%{account_id: author.id, text: "more #gardening"})

      assert status.id in home_ids(reader)
    end

    test "unfollowing one takes them back out", %{author: author, reader: reader} do
      {:ok, tag} = Statuses.upsert_tag("gardening")
      :ok = Statuses.follow_tag(reader, tag)
      status_fixture(%{account_id: author.id, text: "about #gardening"})

      :ok = Statuses.unfollow_tag(reader, tag)

      assert home_ids(reader) == []
    end

    test "leaves a post still reachable through a follow", %{author: author, reader: reader} do
      {:ok, _} = Relationships.follow(reader, author)
      {:ok, tag} = Statuses.upsert_tag("gardening")
      :ok = Statuses.follow_tag(reader, tag)

      status = status_fixture(%{account_id: author.id, text: "about #gardening"})

      :ok = Statuses.unfollow_tag(reader, tag)

      assert status.id in home_ids(reader)
    end

    test "a private post never arrives through a tag", %{author: author, reader: reader} do
      {:ok, tag} = Statuses.upsert_tag("gardening")
      :ok = Statuses.follow_tag(reader, tag)

      status =
        status_fixture(%{account_id: author.id, text: "quiet #gardening", visibility: :private})

      refute status.id in home_ids(reader)
    end
  end

  describe "lists" do
    setup %{author: author, reader: reader} do
      {:ok, _} = Relationships.follow(reader, author)
      {:ok, list} = Lists.create(reader, %{title: "Friends"})

      %{list: list}
    end

    test "adding somebody brings their recent posts into the list", %{
      author: author,
      list: list
    } do
      status = status_fixture(%{account_id: author.id, text: "hello"})

      :ok = Lists.add(list, [author.id])

      assert status.id in Feed.status_ids("list", list.id, %{limit: 100})
    end

    test "removing them takes the posts back out", %{author: author, list: list} do
      status_fixture(%{account_id: author.id, text: "hello"})
      :ok = Lists.add(list, [author.id])

      :ok = Lists.remove(list, [author.id])

      assert Feed.status_ids("list", list.id, %{limit: 100}) == []
    end
  end

  describe "coming back after a long time away" do
    test "an empty feed is rebuilt rather than shown as nothing", %{
      author: author,
      reader: reader
    } do
      # Somebody whose feed was trimmed away while they were gone should not be
      # told there is nothing to read.
      {:ok, _} = Relationships.follow(reader, author)
      status_fixture(%{account_id: author.id, text: "while you were away"})
      Feed.clear("home", reader.id)

      assert Timelines.regenerating?(reader)
    end

    test "a feed with something in it is not rebuilt", %{author: author, reader: reader} do
      {:ok, _} = Relationships.follow(reader, author)
      status_fixture(%{account_id: author.id, text: "hello"})

      refute Timelines.regenerating?(reader)
    end

    test "an empty feed that is empty on purpose is not waiting", %{
      author: author,
      reader: reader
    } do
      # Everybody they follow is in an exclusive list, so the home feed is
      # empty by design. Promising a rebuild would be promising something that
      # never arrives.
      {:ok, _} = Relationships.follow(reader, author)
      {:ok, list} = Lists.create(reader, %{title: "Only", exclusive: true})
      :ok = Lists.add(list, [author.id])
      Feed.clear("home", reader.id)

      refute Timelines.regenerating?(reader)
    end

    test "somebody following nobody is not waiting for anything", %{reader: reader} do
      # An empty feed with nothing to put in it is finished, not pending.
      refute Timelines.regenerating?(reader)
    end

    test "rebuilding fills the feed from everybody they follow", %{
      author: author,
      reader: reader
    } do
      {:ok, _} = Relationships.follow(reader, author)
      status = status_fixture(%{account_id: author.id, text: "while you were away"})
      Feed.clear("home", reader.id)

      assert :ok = perform_job(Abuuba.Timelines.RegenerateWorker, %{"account_id" => reader.id})

      assert status.id in home_ids(reader)
    end
  end
end
