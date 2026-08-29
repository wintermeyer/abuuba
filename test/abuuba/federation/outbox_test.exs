defmodule Abuuba.Federation.OutboxTest do
  @moduledoc """
  That an ordinary thing somebody does here reaches the rest of the network.

  Both halves of this were built and tested before anything joined them:
  `Abuuba.Federation.Serializer` could build every activity, `Abuuba.Federation.
  Delivery` could sign, batch and retry them, and nothing called the second
  with the output of the first. From either side the tests were green. So
  these assertions start at the domain function a person's click reaches and
  end at the queue, which is the seam that was missing.
  """

  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Serializer
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Statuses

  @peer "peer.example"

  defp watcher(username \\ "watcher") do
    remote_account_fixture(%{
      username: username,
      domain: @peer,
      uri: "https://#{@peer}/users/#{username}",
      inbox_url: "https://#{@peer}/users/#{username}/inbox"
    })
  end

  # An author whose posts have somewhere to go.
  defp author_with_follower do
    author = account_fixture()
    follower = watcher()
    {:ok, _follow} = Relationships.follow(follower, author)
    Repo.delete_all(Oban.Job)

    {author, follower}
  end

  defp queued_activities do
    Oban.Job
    |> Repo.all()
    |> Enum.filter(&(&1.worker == "Abuuba.Federation.DeliveryWorker"))
    |> Enum.map(& &1.args["activity"])
  end

  defp queued_types, do: Enum.map(queued_activities(), & &1["type"])

  describe "posts" do
    test "a new one goes to the people following its author" do
      {author, _follower} = author_with_follower()

      {:ok, status} =
        Statuses.create_status(%{account_id: author.id, text: "hello", visibility: :public})

      assert [activity] = queued_activities()
      assert activity["type"] == "Create"
      assert activity["object"]["id"] == Serializer.status_uri(status, author)
    end

    test "one that arrived from somewhere else does not go back out" do
      # It is not ours to republish, and sending it would loop it around the
      # network with our name on the delivery.
      author = account_fixture()
      _follower = watcher()
      remote = remote_account_fixture(%{domain: @peer, uri: "https://#{@peer}/users/other"})
      {:ok, _follow} = Relationships.follow(watcher("second"), author)
      Repo.delete_all(Oban.Job)

      {:ok, _status} =
        Statuses.create_status(%{
          account_id: remote.id,
          text: "theirs",
          local: false,
          uri: "https://#{@peer}/s/1"
        })

      assert queued_types() == []
    end

    test "an edit is announced, so a peer does not keep showing the old words" do
      {author, _follower} = author_with_follower()
      status = status_fixture(%{account_id: author.id, text: "before"})
      Repo.delete_all(Oban.Job)

      {:ok, _updated} = Statuses.edit_status(status, %{text: "after"})

      assert "Update" in queued_types()
    end

    test "a deletion is announced, or the post lives on everywhere else" do
      {author, _follower} = author_with_follower()
      status = status_fixture(%{account_id: author.id})
      Repo.delete_all(Oban.Job)

      {:ok, _deleted} = Statuses.delete_status(status)

      assert "Delete" in queued_types()
    end

    test "a direct message reaches the person it names and nobody else" do
      author = account_fixture()
      stranger = watcher("stranger")
      named = watcher("named")
      {:ok, _follow} = Relationships.follow(stranger, author)
      Repo.delete_all(Oban.Job)

      {:ok, _status} =
        Statuses.create_status(%{
          account_id: author.id,
          text: "@named@#{@peer} just you",
          visibility: :direct
        })

      inboxes = Oban.Job |> Repo.all() |> Enum.map(& &1.args["inbox"])

      assert inboxes == [named.inbox_url]
    end
  end

  describe "audience" do
    test "a limited post reaches the people it names and no follower" do
      # Same rule as a direct message, and the same leak if it is missed.
      author = account_fixture()
      stranger = watcher("stranger")
      named = watcher("named")
      {:ok, _follow} = Relationships.follow(stranger, author)
      Repo.delete_all(Oban.Job)

      {:ok, _status} =
        Statuses.create_status(%{
          account_id: author.id,
          text: "@named@#{@peer} a few of us",
          visibility: :limited
        })

      inboxes = Oban.Job |> Repo.all() |> Enum.map(& &1.args["inbox"])

      assert inboxes == [named.inbox_url]
    end

    test "a followers-only post does reach the followers, so the two above mean something" do
      {author, follower} = author_with_follower()

      {:ok, _status} =
        Statuses.create_status(%{account_id: author.id, text: "just us", visibility: :private})

      inboxes = Oban.Job |> Repo.all() |> Enum.map(& &1.args["inbox"])

      assert inboxes == [follower.inbox_url]
    end
  end

  describe "boosts and favourites" do
    test "a boost is announced" do
      {author, _follower} = author_with_follower()
      original = status_fixture(%{account_id: account_fixture().id})
      Repo.delete_all(Oban.Job)

      {:ok, _boost} = Statuses.boost(author, original)

      assert "Announce" in queued_types()
    end

    test "taking a boost back undoes the announcement it made" do
      {author, _follower} = author_with_follower()
      original = status_fixture(%{account_id: account_fixture().id})
      {:ok, _boost} = Statuses.boost(author, original)
      Repo.delete_all(Oban.Job)

      :ok = Statuses.unboost(author, original)

      assert [%{"type" => "Undo", "object" => %{"type" => "Announce"}}] = queued_activities()
    end

    test "a favourite reaches the author of what was favourited" do
      author = account_fixture()
      remote = watcher("liked")
      theirs = status_fixture(%{account_id: remote.id, local: false, uri: "https://#{@peer}/s/7"})
      Repo.delete_all(Oban.Job)

      {:ok, _favourite} = Statuses.favourite(author, theirs)

      assert ["Like"] = queued_types()
    end

    test "and taking it back undoes it" do
      author = account_fixture()
      remote = watcher("liked")
      theirs = status_fixture(%{account_id: remote.id, local: false, uri: "https://#{@peer}/s/7"})
      {:ok, _favourite} = Statuses.favourite(author, theirs)
      Repo.delete_all(Oban.Job)

      :ok = Statuses.unfavourite(author, theirs)

      assert [%{"type" => "Undo", "object" => %{"type" => "Like"}}] = queued_activities()
    end

    test "favouriting somebody here sends nothing, because there is nobody to tell" do
      author = account_fixture()
      theirs = status_fixture(%{account_id: account_fixture().id})
      Repo.delete_all(Oban.Job)

      {:ok, _favourite} = Statuses.favourite(author, theirs)

      assert queued_types() == []
    end
  end

  describe "relationships" do
    test "following somebody elsewhere asks their server" do
      follower = account_fixture()
      target = watcher("followed")
      Repo.delete_all(Oban.Job)

      {:ok, _follow} = Relationships.follow(follower, target)

      assert ["Follow"] = queued_types()
    end

    test "unfollowing takes the request back" do
      follower = account_fixture()
      target = watcher("followed")
      {:ok, _follow} = Relationships.follow(follower, target)
      Repo.delete_all(Oban.Job)

      :ok = Relationships.unfollow(follower, target)

      assert [%{"type" => "Undo", "object" => %{"type" => "Follow"}}] = queued_activities()
    end

    test "accepting a request tells the asker they are in" do
      target = account_fixture(%{locked: true})
      asker = watcher("asker")
      {:ok, request} = Relationships.request_follow(asker, target)
      Repo.delete_all(Oban.Job)

      {:ok, _follow} = Relationships.accept_follow_request(request)

      assert ["Accept"] = queued_types()
    end

    test "rejecting one tells them too, rather than leaving them waiting" do
      target = account_fixture(%{locked: true})
      asker = watcher("asker")
      {:ok, request} = Relationships.request_follow(asker, target)
      Repo.delete_all(Oban.Job)

      :ok = Relationships.reject_follow_request(request)

      assert ["Reject"] = queued_types()
    end

    test "a block is sent, so their server stops delivering to us" do
      blocker = account_fixture()
      target = watcher("blocked")
      Repo.delete_all(Oban.Job)

      {:ok, _block} = Relationships.block(blocker, target)

      assert "Block" in queued_types()
    end

    test "and lifting it is undone" do
      blocker = account_fixture()
      target = watcher("blocked")
      {:ok, _block} = Relationships.block(blocker, target)
      Repo.delete_all(Oban.Job)

      :ok = Relationships.unblock(blocker, target)

      assert [%{"type" => "Undo", "object" => %{"type" => "Block"}}] = queued_activities()
    end
  end

  describe "profiles and pins" do
    test "an edited profile is announced, so peers stop showing the old one" do
      {author, _follower} = author_with_follower()

      {:ok, _account} = Accounts.update_profile(author, %{"display_name" => "New Name"})

      assert [%{"type" => "Update", "object" => %{"type" => "Person"}}] = queued_activities()
    end

    test "pinning a post adds it to the featured collection peers read" do
      {author, _follower} = author_with_follower()
      status = status_fixture(%{account_id: author.id})
      Repo.delete_all(Oban.Job)

      {:ok, _pin} = Statuses.pin(author, status)

      assert ["Add"] = queued_types()
    end

    test "featuring a hashtag is announced the same way" do
      {author, _follower} = author_with_follower()
      {:ok, tag} = Statuses.upsert_tag("gardening")
      Repo.delete_all(Oban.Job)

      :ok = Statuses.feature_tag(author, tag)

      assert [%{"type" => "Add", "object" => %{"type" => "Hashtag", "name" => "#gardening"}}] =
               queued_activities()

      Repo.delete_all(Oban.Job)
      :ok = Statuses.unfeature_tag(author, tag)

      assert [%{"type" => "Remove", "object" => %{"type" => "Hashtag"}}] = queued_activities()
    end

    test "featuring a hashtag that is already there tells nobody" do
      # Peers cache a profile's collections. Announcing a change that did not
      # happen is a delivery to every follower for nothing.
      {author, _follower} = author_with_follower()
      {:ok, tag} = Statuses.upsert_tag("gardening")
      :ok = Statuses.feature_tag(author, tag)
      Repo.delete_all(Oban.Job)

      {:ok, other} = Statuses.upsert_tag("neverfeatured")

      :ok = Statuses.feature_tag(author, tag)
      :ok = Statuses.unfeature_tag(author, other)

      assert queued_types() == []
    end

    test "unpinning removes it" do
      {author, _follower} = author_with_follower()
      status = status_fixture(%{account_id: author.id})
      {:ok, _pin} = Statuses.pin(author, status)
      Repo.delete_all(Oban.Job)

      :ok = Statuses.unpin(author, status)

      assert ["Remove"] = queued_types()
    end
  end

  describe "what is signed and where it goes" do
    test "every delivery is signed by the account whose activity it is" do
      {author, _follower} = author_with_follower()

      {:ok, _status} = Statuses.create_status(%{account_id: author.id, text: "hello"})

      assert [job] = Repo.all(Oban.Job)
      assert job.args["account_id"] == author.id
    end

    test "an account with no remote followers queues nothing at all" do
      # The positive cases above would all pass just as happily if every call
      # queued a job unconditionally, so this is the one that says the audience
      # is being worked out rather than ignored.
      author = account_fixture()

      {:ok, _status} = Statuses.create_status(%{account_id: author.id, text: "into the void"})

      assert Repo.aggregate(Oban.Job, :count) == 0
    end
  end

  describe "a vote on somebody else's poll" do
    test "is sent to the server that owns it, one activity per option" do
      # One per option because that is how a multiple-choice vote travels:
      # there is no way to say "these three" in a single activity.
      author = remote_account_fixture(%{username: "pollster", domain: "remote.example"})

      status =
        status_fixture(%{
          account_id: author.id,
          uri: "https://remote.example/statuses/poll",
          local: false
        })

      {:ok, poll} =
        Abuuba.Statuses.create_poll(status, %{
          options: ["tea", "coffee"],
          multiple: true,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      voter = account_fixture(%{username: "voter"})

      {:ok, _poll} = Abuuba.Statuses.vote(poll, voter, [0, 1])

      votes = Enum.filter(queued_activities(), &(&1["type"] == "Create"))

      assert length(votes) == 2

      names = votes |> Enum.map(& &1["object"]["name"]) |> Enum.sort()
      assert names == ["coffee", "tea"]

      for vote <- votes do
        assert vote["object"]["inReplyTo"] == status.uri
        assert vote["object"]["attributedTo"] == Actor.id(voter)
        assert vote["to"] == [Actor.id(author)]
        refute Map.has_key?(vote["object"], "content")
      end
    end

    test "and a vote on one of our own polls goes nowhere" do
      author = account_fixture(%{username: "localpollster"})
      status = status_fixture(%{account_id: author.id})

      {:ok, poll} =
        Abuuba.Statuses.create_poll(status, %{
          options: ["a", "b"],
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      voter = account_fixture(%{username: "localvoter"})

      {:ok, _poll} = Abuuba.Statuses.vote(poll, voter, [0])

      assert Enum.filter(queued_activities(), &(&1["type"] == "Create")) == []
    end
  end
end
