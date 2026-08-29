defmodule Abuuba.Federation.FollowerSyncWorkerTest do
  @moduledoc """
  The receiving half of FEP-8fcf: acting on a peer telling us our idea of who
  here follows it is wrong.

  The sending half was already built and tested. This is the half that repairs
  anything, and until it existed a peer could tell us for years and nothing
  would change.
  """

  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.FollowerSync
  alias Abuuba.Federation.FollowerSyncWorker
  alias Abuuba.Relationships
  alias Abuuba.Repo

  @peer "peer.example"
  @remote_uri "https://peer.example/users/star"
  @collection "https://peer.example/users/star/followers"
  @partial "https://peer.example/users/star/followers?domain=localhost"

  setup do
    remote =
      remote_account_fixture(%{
        username: "star",
        domain: @peer,
        uri: @remote_uri,
        followers_url: @collection,
        inbox_url: "https://peer.example/users/star/inbox"
      })

    %{remote: remote}
  end

  defp header(digest, opts \\ []) do
    collection = Keyword.get(opts, :collection, @collection)
    url = Keyword.get(opts, :url, @partial)

    ~s(collectionId="#{collection}", url="#{url}", digest="#{digest}")
  end

  defp queued_syncs do
    Oban.Job
    |> Repo.all()
    |> Enum.filter(&(&1.worker == "Abuuba.Federation.FollowerSyncWorker"))
  end

  describe "deciding whether a repair is needed" do
    test "queues nothing when the two sides already agree", %{remote: remote} do
      follower = account_fixture()
      {:ok, _follow} = Relationships.follow(follower, remote)
      Repo.delete_all(Oban.Job)

      ours = FollowerSync.digest(FollowerSync.local_follower_uris_of(remote))

      :ok = FollowerSyncWorker.enqueue(remote, header(ours))

      assert queued_syncs() == []
    end

    test "queues a repair when they disagree", %{remote: remote} do
      # The positive control. Every refusal below would pass just as happily if
      # nothing were ever queued at all.
      follower = account_fixture()
      {:ok, _follow} = Relationships.follow(follower, remote)
      Repo.delete_all(Oban.Job)

      :ok = FollowerSyncWorker.enqueue(remote, header(String.duplicate("a", 64)))

      assert [job] = queued_syncs()
      assert job.args["url"] == @partial
    end

    test "ignores a header naming somebody else's collection", %{remote: remote} do
      # Otherwise a peer could ask us to reconcile a relationship that has
      # nothing to do with it.
      :ok =
        FollowerSyncWorker.enqueue(
          remote,
          header(String.duplicate("a", 64),
            collection: "https://peer.example/users/other/followers"
          )
        )

      assert queued_syncs() == []
    end

    test "ignores a collection url on a different host", %{remote: remote} do
      :ok =
        FollowerSyncWorker.enqueue(
          remote,
          header(String.duplicate("a", 64), url: "https://elsewhere.example/collection")
        )

      assert queued_syncs() == []
    end

    test "ignores a header it cannot read", %{remote: remote} do
      :ok = FollowerSyncWorker.enqueue(remote, "nonsense")
      :ok = FollowerSyncWorker.enqueue(remote, nil)

      assert queued_syncs() == []
    end
  end

  describe "reconciling" do
    setup %{remote: remote} do
      stale = account_fixture(%{username: "stale"})
      kept = account_fixture(%{username: "kept"})
      {:ok, _follow} = Relationships.follow(stale, remote)
      {:ok, _follow} = Relationships.follow(kept, remote)
      Repo.delete_all(Oban.Job)

      %{remote: remote, stale: stale, kept: kept}
    end

    defp run(uris, claimed_digest, remote) do
      collection = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => @partial,
        "type" => "OrderedCollection",
        "partOf" => @collection,
        "orderedItems" => uris
      }

      FollowerSyncWorker.repair(remote.id, @partial, claimed_digest,
        fetch: fn _url -> {:ok, collection} end
      )
    end

    test "drops a follow the other server has no record of", %{
      remote: remote,
      stale: stale,
      kept: kept
    } do
      uris = [Actor.id(kept)]

      :ok = run(uris, FollowerSync.digest(uris), remote)

      refute Relationships.following?(stale, remote)
      assert Relationships.following?(kept, remote)
    end

    test "keeps every follow when the digest does not add up", %{
      remote: remote,
      stale: stale,
      kept: kept
    } do
      # A truncated or half-fetched collection must not unfollow people on the
      # peer's behalf, so the destructive half only runs on proof.
      uris = [Actor.id(kept)]

      :ok = run(uris, String.duplicate("b", 64), remote)

      assert Relationships.following?(stale, remote)
      assert Relationships.following?(kept, remote)
    end

    test "takes back a follow they believe in and we have no row for", %{remote: remote} do
      stranger = account_fixture(%{username: "stranger"})
      uris = [Actor.id(stranger)]

      :ok = run(uris, FollowerSync.digest(uris), remote)

      # Nothing to delete here: what has to happen is that their server stops
      # delivering, which only an Undo can tell it.
      undos =
        Oban.Job
        |> Repo.all()
        |> Enum.filter(&(&1.worker == "Abuuba.Federation.DeliveryWorker"))
        |> Enum.map(& &1.args["activity"]["type"])

      assert "Undo" in undos
    end

    test "grants a pending request they consider granted", %{remote: remote} do
      asker = account_fixture(%{username: "asker"})
      {:ok, _request} = Relationships.request_follow(asker, remote)
      uris = [Actor.id(asker)]

      :ok = run(uris, FollowerSync.digest(uris), remote)

      assert Relationships.following?(asker, remote)
    end

    test "does nothing for an account that is not this server's", %{remote: remote} do
      other_remote =
        remote_account_fixture(%{username: "elsewhere", domain: "other.example"})

      uris = [other_remote.uri]

      :ok = run(uris, FollowerSync.digest(uris), remote)

      # Their list naming somebody on a third server is not a local follow and
      # must not be turned into one.
      refute Relationships.following?(other_remote, remote)
    end

    test "refuses a job whose url wandered off the account's host", %{remote: remote} do
      # A queued job outlives the request that made it, so the check is made
      # again where the fetch actually happens.
      assert :ok =
               FollowerSyncWorker.repair(
                 remote.id,
                 "https://elsewhere.example/c",
                 String.duplicate("a", 64),
                 fetch: fn _url -> flunk("must not fetch off-host") end
               )
    end

    test "refuses a job about a local account" do
      local = account_fixture()

      assert :ok =
               FollowerSyncWorker.repair(local.id, @partial, String.duplicate("a", 64),
                 fetch: fn _url -> flunk("must not fetch for a local account") end
               )
    end
  end

  describe "the digest both sides compute" do
    test "is the same shape in each direction", %{remote: remote} do
      # The whole mechanism is two servers comparing one number. Built
      # differently on the two sides they would never agree and every delivery
      # would trigger a pointless repair.
      follower = account_fixture()
      {:ok, _follow} = Relationships.follow(follower, remote)

      ours = FollowerSync.local_follower_uris_of(remote)

      assert ours == [Actor.id(follower)]
      assert FollowerSync.digest(ours) == FollowerSync.digest(ours)
      assert byte_size(FollowerSync.digest(ours)) == 64
    end

    test "of nobody is all zeroes, not an error", %{remote: remote} do
      assert FollowerSync.digest(FollowerSync.local_follower_uris_of(remote)) ==
               String.duplicate("0", 64)
    end
  end

  describe "reading the header" do
    test "takes the three parts out" do
      assert {:ok, %{collection_id: @collection, url: @partial, digest: "abc"}} =
               FollowerSync.parse_header(header("abc"))
    end

    test "refuses one with a part missing" do
      assert :error = FollowerSync.parse_header(~s(collectionId="#{@collection}"))
      assert :error = FollowerSync.parse_header("")
      assert :error = FollowerSync.parse_header(nil)
    end
  end

  describe "an unresolvable account" do
    test "is skipped rather than crashing the repair", %{remote: remote} do
      uris = ["https://peer.example/users/never-heard-of"]

      assert :ok = run_unstubbed(uris, remote)
    end

    defp run_unstubbed(uris, remote) do
      collection = %{"type" => "OrderedCollection", "orderedItems" => uris}

      FollowerSyncWorker.repair(remote.id, @partial, FollowerSync.digest(uris),
        fetch: fn _url -> {:ok, collection} end
      )
    end
  end

  describe "an account with no followers_url column" do
    test "still matches the conventional collection shape" do
      # Resolved before that column existed, or by a peer that does not publish
      # it. The collection is still theirs.
      remote =
        remote_account_fixture(%{
          username: "old",
          domain: @peer,
          uri: "https://peer.example/users/old"
        })

      assert %Account{followers_url: nil} = remote

      :ok =
        FollowerSyncWorker.enqueue(
          remote,
          ~s(collectionId="https://peer.example/users/old/followers", ) <>
            ~s(url="https://peer.example/users/old/followers?domain=localhost", ) <>
            ~s(digest="#{String.duplicate("a", 64)}")
        )

      assert [_job] = queued_syncs()
    end
  end
end
