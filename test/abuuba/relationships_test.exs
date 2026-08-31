defmodule Abuuba.RelationshipsTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Notifications
  alias Abuuba.Relationships
  alias Abuuba.Relationships.Follow
  alias Abuuba.Relationships.FollowRequest
  alias Abuuba.Relationships.Mute
  alias Abuuba.Stats
  alias Abuuba.Statuses

  setup do
    %{alice: account_fixture(), bob: account_fixture(), carol: account_fixture()}
  end

  describe "following" do
    test "records the edge in one direction only", %{alice: alice, bob: bob} do
      assert {:ok, follow} = Relationships.follow(alice, bob)

      assert follow.account_id == alice.id
      assert follow.target_account_id == bob.id
      assert Relationships.following?(alice, bob)
      refute Relationships.following?(bob, alice)
    end

    test "the follower list pages min_id from the near end", %{alice: alice} do
      followers = for _ <- 1..3, do: account_fixture()
      for follower <- followers, do: {:ok, _} = Relationships.follow(follower, alice)

      [oldest, middle, _newest] = Enum.sort_by(followers, & &1.id)

      assert Enum.map(
               Relationships.followers(alice, nil, %{min_id: oldest.id, limit: 1}),
               & &1.id
             ) == [middle.id]
    end

    test "a follower list answers to the reader, on every surface", %{alice: alice, bob: bob} do
      # The viewer used to be an optional key inside the pagination map, so
      # the filter was a no-op unless a caller remembered to fill it in: the
      # REST endpoint did and the profile page did not, and blocking somebody
      # hid them from an app while leaving them in the browser.
      {:ok, _} = Relationships.follow(bob, alice)

      elsewhere = remote_account_fixture(%{domain: "loud.example"})
      {:ok, _} = Relationships.follow(elsewhere, alice)

      reader = account_fixture()

      assert length(Relationships.followers(alice, reader)) == 2

      {:ok, _} = Relationships.block(reader, bob)
      {:ok, _} = Relationships.block_domain(reader, "loud.example")

      assert Relationships.followers(alice, reader) == [],
             "a block and a blocked server both count, which the domain half did not"

      assert length(Relationships.followers(alice, nil)) == 2,
             "and a list nobody is reading on their own behalf is untouched"
    end

    test "so does the list of who somebody follows", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.follow(alice, bob)
      reader = account_fixture()

      assert Enum.map(Relationships.following(alice, reader), & &1.id) == [bob.id]

      {:ok, _} = Relationships.mute(reader, bob)

      assert Relationships.following(alice, reader) == []
    end

    test "familiar followers cap at five per target, newest first", %{alice: alice, bob: bob} do
      carol = account_fixture()
      mutuals = for _ <- 1..6, do: account_fixture()

      for mutual <- mutuals do
        {:ok, _} = Relationships.follow(alice, mutual)
        {:ok, _} = Relationships.follow(mutual, bob)
      end

      [{answer_for_bob, familiar}, {answer_for_carol, nobody}] =
        Relationships.familiar_followers(alice, [bob.id, carol.id])

      assert answer_for_bob == bob.id
      assert answer_for_carol == carol.id
      assert nobody == []

      expected =
        mutuals |> Enum.map(& &1.id) |> Enum.sort(:desc) |> Enum.take(5)

      assert Enum.map(familiar, & &1.id) == expected
    end

    test "between/2 answers both directions at once", %{alice: alice, bob: bob} do
      assert Relationships.between(alice.id, bob.id) == %{following: false, followed_by: false}

      {:ok, _} = Relationships.follow(alice, bob)

      assert Relationships.between(alice.id, bob.id) == %{following: true, followed_by: false}
      assert Relationships.between(bob.id, alice.id) == %{following: false, followed_by: true}
    end

    test "defaults to boosts shown and no per-post notifications", %{alice: alice, bob: bob} do
      {:ok, follow} = Relationships.follow(alice, bob)

      assert follow.show_reblogs
      refute follow.notify
    end

    test "carries a per-follow language filter", %{alice: alice, bob: bob} do
      {:ok, follow} = Relationships.follow(alice, bob, %{languages: ["de", "en"]})

      assert follow.languages == ["de", "en"]
    end

    test "twice is once, with the second one changing the options", %{alice: alice, bob: bob} do
      # "Follow, but not the boosts" arrives as the same request whether or not
      # the follow already exists, so a duplicate updates rather than refusing.
      {:ok, _} = Relationships.follow(alice, bob)

      assert {:ok, follow} = Relationships.follow(alice, bob, %{show_reblogs: false})
      refute follow.show_reblogs
      assert Relationships.following?(alice, bob)
    end

    test "twice does not count twice", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.follow(alice, bob)
      {:ok, _} = Relationships.follow(alice, bob)

      assert Abuuba.Accounts.get_account(bob.id) |> then(& &1.id) == bob.id
      assert length(Relationships.followers(bob, nil, %{})) == 1
    end

    test "cannot point at yourself", %{alice: alice} do
      assert {:error, changeset} = Relationships.follow(alice, alice)
      assert errors_on(changeset).target_account_id != []
    end

    test "the database refuses a self-follow even so", %{alice: alice} do
      assert_raise Postgrex.Error, ~r/follows_no_self_reference/, fn ->
        Repo.query!(
          "INSERT INTO follows (account_id, target_account_id, show_reblogs, notify, " <>
            "inserted_at, updated_at) VALUES ($1, $1, true, false, now(), now())",
          [alice.id]
        )
      end
    end

    test "unfollowing is idempotent, so a retry is not an error", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.follow(alice, bob)

      assert :ok = Relationships.unfollow(alice, bob)
      assert :ok = Relationships.unfollow(alice, bob)
      refute Relationships.following?(alice, bob)
    end

    test "lists both directions of the graph", %{alice: alice, bob: bob, carol: carol} do
      {:ok, _} = Relationships.follow(alice, bob)
      {:ok, _} = Relationships.follow(carol, bob)

      assert Relationships.following_ids(alice) == [bob.id]
      assert Enum.sort(Relationships.follower_ids(bob)) == Enum.sort([alice.id, carol.id])
      assert Relationships.follower_ids(alice) == []
    end
  end

  describe "follow requests" do
    test "accepting moves the row and keeps every setting", %{alice: alice, bob: bob} do
      {:ok, request} =
        Relationships.request_follow(alice, bob, %{
          show_reblogs: false,
          notify: true,
          languages: ["de"]
        })

      assert {:ok, follow} = Relationships.accept_follow_request(request)

      assert follow.show_reblogs == false
      assert follow.notify == true
      assert follow.languages == ["de"]

      assert Relationships.following?(alice, bob)
      assert Relationships.get_follow_request(alice, bob) == nil
    end

    test "rejecting leaves no follow behind", %{alice: alice, bob: bob} do
      {:ok, request} = Relationships.request_follow(alice, bob)

      assert :ok = Relationships.reject_follow_request(request)
      refute Relationships.following?(alice, bob)
      assert Relationships.get_follow_request(alice, bob) == nil
    end

    test "cannot be made twice", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.request_follow(alice, bob)

      assert {:error, changeset} = Relationships.request_follow(alice, bob)
      assert errors_on(changeset).account_id != []
    end

    test "is withdrawn by the person who asked", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.request_follow(alice, bob)

      assert :ok = Relationships.unfollow(alice, bob)

      assert Relationships.get_follow_request(alice, bob) == nil
      refute Relationships.following?(alice, bob)
    end

    test "withdrawing takes the notification asking about it", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.request_follow(alice, bob)

      Relationships.unfollow(alice, bob)

      assert Notifications.list(bob) == []
    end
  end

  describe "following an account that approves its followers" do
    setup do
      %{locked: account_fixture(%{locked: true})}
    end

    test "asks instead of following", %{alice: alice, locked: locked} do
      assert {:ok, %FollowRequest{}} = Relationships.follow_or_request(alice, locked)

      refute Relationships.following?(alice, locked)
      assert Relationships.get_follow_request(alice, locked)
    end

    test "follows anybody else outright", %{alice: alice, bob: bob} do
      assert {:ok, %Follow{}} = Relationships.follow_or_request(alice, bob)

      assert Relationships.following?(alice, bob)
    end

    test "carries the options into the request", %{alice: alice, locked: locked} do
      {:ok, request} =
        Relationships.follow_or_request(alice, locked, %{show_reblogs: false, languages: ["de"]})

      assert request.show_reblogs == false
      assert request.languages == ["de"]
    end

    # Somebody who locks their account after granting a follow has already said
    # yes to the people following them, and a repeat follow is how the options
    # on that follow are changed. Asking again would hand them a question about
    # somebody they already answered for.
    test "changes an existing follow rather than asking again", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.follow(alice, bob)
      {:ok, locked} = Accounts.update_account(bob, %{locked: true})

      assert {:ok, %Follow{}} =
               Relationships.follow_or_request(alice, locked, %{show_reblogs: false})

      assert Relationships.get_follow_request(alice, locked) == nil
      refute Relationships.get_follow(alice, locked).show_reblogs
    end

    test "asking twice is one request, not an error", %{alice: alice, locked: locked} do
      {:ok, _} = Relationships.follow_or_request(alice, locked)

      assert {:ok, request} =
               Relationships.follow_or_request(alice, locked, %{show_reblogs: false})

      assert request.show_reblogs == false
    end

    test "is refused where either has blocked the other", %{alice: alice, locked: locked} do
      {:ok, _} = Relationships.block(locked, alice)

      assert {:error, :blocked} = Relationships.follow_or_request(alice, locked)
    end
  end

  describe "blocking" do
    test "severs follows in both directions", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.follow(alice, bob)
      {:ok, _} = Relationships.follow(bob, alice)

      assert {:ok, _} = Relationships.block(alice, bob)

      refute Relationships.following?(alice, bob)

      refute Relationships.following?(bob, alice),
             "a blocked account left following would report blocking and followed_by at once"
    end

    test "withdraws pending requests in both directions", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.request_follow(alice, bob)
      {:ok, _} = Relationships.request_follow(bob, alice)

      {:ok, _} = Relationships.block(alice, bob)

      assert Relationships.get_follow_request(alice, bob) == nil
      assert Relationships.get_follow_request(bob, alice) == nil
    end

    test "stops a new follow in either direction", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.block(alice, bob)

      assert {:error, :blocked} = Relationships.follow(alice, bob)
      assert {:error, :blocked} = Relationships.follow(bob, alice)
      assert {:error, :blocked} = Relationships.request_follow(bob, alice)
    end

    test "unblocking does not restore what the block tore down", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.follow(bob, alice)
      {:ok, _} = Relationships.block(alice, bob)

      assert :ok = Relationships.unblock(alice, bob)

      refute Relationships.blocking?(alice, bob)
      refute Relationships.following?(bob, alice)
      assert {:ok, _} = Relationships.follow(bob, alice)
    end

    test "cannot point at yourself", %{alice: alice} do
      assert {:error, changeset} = Relationships.block(alice, alice)
      assert errors_on(changeset).target_account_id != []
    end
  end

  describe "muting" do
    test "does not touch the follow, which is the point", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.follow(alice, bob)

      assert {:ok, _} = Relationships.mute(alice, bob)
      assert Relationships.muting?(alice, bob)
      assert Relationships.following?(alice, bob)
    end

    test "hides notifications by default, and need not", %{alice: alice, bob: bob, carol: carol} do
      {:ok, loud} = Relationships.mute(alice, bob)
      {:ok, quiet} = Relationships.mute(alice, carol, %{hide_notifications: false})

      assert loud.hide_notifications
      refute quiet.hide_notifications
    end

    test "an expired mute is not in force", %{alice: alice, bob: bob} do
      {:ok, _} =
        Relationships.mute(alice, bob, %{expires_at: DateTime.add(DateTime.utc_now(), -1)})

      refute Relationships.muting?(alice, bob)
    end

    test "a mute expiring later is in force", %{alice: alice, bob: bob} do
      {:ok, mute} =
        Relationships.mute(alice, bob, %{
          expires_at: DateTime.add(DateTime.utc_now(), 3600)
        })

      assert Mute.active?(mute)
      assert Relationships.muting?(alice, bob)
    end

    test "the sweeper removes expired mutes and leaves the rest", %{
      alice: alice,
      bob: bob,
      carol: carol
    } do
      {:ok, _} =
        Relationships.mute(alice, bob, %{expires_at: DateTime.add(DateTime.utc_now(), -1)})

      {:ok, _} = Relationships.mute(alice, carol)

      assert Relationships.expire_mutes() == 1
      assert Relationships.muting?(alice, carol)
    end
  end

  describe "personal domain blocks" do
    test "are recorded casefolded, so a block written any way still matches", %{alice: alice} do
      assert {:ok, block} = Relationships.block_domain(alice, " Spam.Example ")

      assert block.domain == "spam.example"
      assert Relationships.blocking_domain?(alice, "SPAM.EXAMPLE")
      assert Relationships.blocking_domain?(alice, "spam.example")
    end

    test "affect only their owner", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.block_domain(alice, "spam.example")

      refute Relationships.blocking_domain?(bob, "spam.example")
    end

    test "a local account has no domain to be blocked by", %{alice: alice} do
      refute Relationships.blocking_domain?(alice, nil)
    end

    test "can be lifted", %{alice: alice} do
      {:ok, _} = Relationships.block_domain(alice, "spam.example")

      assert :ok = Relationships.unblock_domain(alice, "Spam.Example")
      refute Relationships.blocking_domain?(alice, "spam.example")
    end
  end

  describe "private notes" do
    test "are written and rewritten in place", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.put_note(alice, bob, "met at a conference")
      {:ok, note} = Relationships.put_note(alice, bob, "actually, met online")

      assert note.comment == "actually, met online"
      assert Relationships.get_note(alice, bob).comment == "actually, met online"
    end

    test "are not visible to their subject", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.put_note(alice, bob, "loud")

      assert Relationships.get_note(bob, alice) == nil
    end
  end

  describe "relationship/2" do
    test "relationships/2 matches the one-by-one answers, in the asked order", %{
      alice: alice,
      bob: bob
    } do
      carol = account_fixture()
      {:ok, _} = Relationships.follow(alice, bob)
      {:ok, _} = Relationships.block(carol, alice)
      {:ok, _} = Relationships.put_note(alice, carol, "met at a conference")

      batched = Relationships.relationships(alice.id, [carol.id, bob.id])

      # Anchored to what the edges above actually are, first. Comparing the
      # batch against `relationship/2` alone would hold just as well if both
      # were wrong in the same way, since the single-id function is now the
      # batch called with one id.
      assert [carol_answer, bob_answer] = batched
      assert carol_answer.id == carol.id
      assert carol_answer.blocked_by
      assert carol_answer.note == "met at a conference"
      refute carol_answer.following
      assert bob_answer.id == bob.id
      assert bob_answer.following
      refute bob_answer.blocked_by

      # And then that asking for two at once answers each the way asking for
      # it on its own does, which is what the batching could get wrong.
      assert batched == [
               Relationships.relationship(alice, carol),
               Relationships.relationship(alice, bob)
             ]
    end

    test "answers everything a client asks in one call", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.follow(alice, bob, %{notify: true, show_reblogs: false})
      {:ok, _} = Relationships.follow(bob, alice)
      {:ok, _} = Relationships.mute(alice, bob)
      {:ok, _} = Relationships.put_note(alice, bob, "a note")

      relationship = Relationships.relationship(alice, bob)

      assert relationship.id == bob.id
      assert relationship.following
      assert relationship.followed_by
      assert relationship.muting
      assert relationship.muting_notifications
      assert relationship.notifying
      refute relationship.showing_reblogs
      refute relationship.blocking
      refute relationship.requested
      assert relationship.note == "a note"
    end

    test "reports a pending request from either side", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.request_follow(alice, bob)

      assert Relationships.relationship(alice, bob).requested
      assert Relationships.relationship(bob, alice).requested_by
    end

    test "reports being blocked as well as blocking", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.block(alice, bob)

      assert Relationships.relationship(alice, bob).blocking
      assert Relationships.relationship(bob, alice).blocked_by
    end

    test "is empty between strangers", %{alice: alice, bob: bob} do
      relationship = Relationships.relationship(alice, bob)

      refute relationship.following
      refute relationship.followed_by
      refute relationship.blocking
      refute relationship.muting
      assert relationship.note == ""
    end
  end

  describe "counter caches" do
    test "start at zero without a row having to exist", %{alice: alice} do
      assert Stats.account_stats(alice) == %{
               statuses_count: 0,
               following_count: 0,
               followers_count: 0,
               last_status_at: nil
             }
    end

    test "follow and unfollow move both sides", %{alice: alice, bob: bob} do
      {:ok, _} = Relationships.follow(alice, bob)

      assert Stats.account_stats(alice).following_count == 1
      assert Stats.account_stats(bob).followers_count == 1

      :ok = Relationships.unfollow(alice, bob)

      assert Stats.account_stats(alice).following_count == 0
      assert Stats.account_stats(bob).followers_count == 0
    end

    test "an unfollow that removed nothing does not move the counters", %{
      alice: alice,
      bob: bob
    } do
      :ok = Relationships.unfollow(alice, bob)

      assert Stats.account_stats(alice).following_count == 0
      assert Stats.account_stats(bob).followers_count == 0
    end

    test "accepting a request counts the follow once", %{alice: alice, bob: bob} do
      {:ok, request} = Relationships.request_follow(alice, bob)

      assert Stats.account_stats(bob).followers_count == 0

      {:ok, _} = Relationships.accept_follow_request(request)

      assert Stats.account_stats(bob).followers_count == 1
    end

    test "increments never read a stale value", %{alice: alice} do
      # A read-modify-write from the value fetched here would end at 1, having
      # silently thrown one of the two increments away.
      before = Stats.account_stats(alice)
      assert before.followers_count == 0

      Stats.bump_account(alice, followers_count: 1)
      Stats.bump_account(alice, followers_count: 1)

      assert Stats.account_stats(alice).followers_count == 2
    end

    test "a status counter behaves the same way" do
      status = status_fixture()

      assert Stats.status_stats(status).favourites_count == 0

      Stats.bump_status(status, favourites_count: 1)
      Stats.bump_status(status, favourites_count: 1)
      Stats.bump_status(status, reblogs_count: 1)

      stats = Stats.status_stats(status)
      assert stats.favourites_count == 2
      assert stats.reblogs_count == 1
      assert stats.replies_count == 0
    end

    test "last_status_at is set, not added to", %{alice: alice} do
      at = DateTime.utc_now()

      Stats.bump_account(alice, statuses_count: 1, last_status_at: at)

      stats = Stats.account_stats(alice)
      assert stats.statuses_count == 1
      assert stats.last_status_at == at
    end

    test "a decrement before anything was counted starts at zero, not below it", %{alice: alice} do
      # Postgres validates the proposed row before it notices the conflict, so
      # an unfloored decrement here would be refused outright.
      Stats.bump_account(alice, followers_count: -1)

      assert Stats.account_stats(alice).followers_count == 0
    end

    test "the database refuses an existing counter driven below zero", %{alice: alice} do
      Stats.bump_account(alice, followers_count: 1)

      assert_raise Postgrex.Error, ~r/account_stats_counts_are_not_negative/, fn ->
        Stats.bump_account(alice, followers_count: -2)
      end
    end

    test "a typo in a counter name fails loudly rather than at the database", %{alice: alice} do
      assert_raise ArgumentError, ~r/unknown counters/, fn ->
        Stats.bump_account(alice, folowers_count: 1)
      end
    end

    test "counters go away with the account they belong to", %{alice: alice} do
      Stats.bump_account(alice, followers_count: 1)
      Repo.delete!(alice)

      assert Repo.query!("SELECT count(*) FROM account_stats WHERE account_id = $1", [alice.id]).rows ==
               [[0]]
    end
  end

  describe "followers-only statuses, now that there is a follow graph" do
    test "are readable by a follower", %{alice: alice, bob: bob} do
      status = status_fixture(%{account_id: alice.id, visibility: :private})

      refute Statuses.get_status(status.id, bob)

      {:ok, _} = Relationships.follow(bob, alice)

      assert Statuses.get_status(status.id, bob),
             "a follower is exactly who a followers-only post is for"
    end

    test "are not readable by somebody the author follows", %{alice: alice, bob: bob} do
      # Following someone does not entitle you to their private posts; being
      # followed by them does.
      status = status_fixture(%{account_id: alice.id, visibility: :private})
      {:ok, _} = Relationships.follow(alice, bob)

      refute Statuses.get_status(status.id, bob)
    end

    test "stop being readable after an unfollow", %{alice: alice, bob: bob} do
      status = status_fixture(%{account_id: alice.id, visibility: :private})
      {:ok, _} = Relationships.follow(bob, alice)

      assert Statuses.get_status(status.id, bob)

      :ok = Relationships.unfollow(bob, alice)

      refute Statuses.get_status(status.id, bob)
    end

    test "a follow does not open up a direct message", %{alice: alice, bob: bob} do
      status = status_fixture(%{account_id: alice.id, visibility: :direct})
      {:ok, _} = Relationships.follow(bob, alice)

      refute Statuses.get_status(status.id, bob),
             "a direct message is for the people it names, not for followers"
    end
  end
end
