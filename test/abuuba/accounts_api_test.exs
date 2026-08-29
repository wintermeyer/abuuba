defmodule Abuuba.AccountsAPITest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Relationships

  describe "looking up a handle" do
    setup do
      %{
        local: account_fixture(%{username: "alice"}),
        remote:
          remote_account_fixture(%{
            username: "alice",
            domain: "remote.example",
            uri: "https://remote.example/users/alice"
          })
      }
    end

    test "in every spelling people paste", %{local: local} do
      for typed <- ["alice", "@alice", " alice ", "@alice@abuuba.test", "alice@abuuba.test"] do
        assert Accounts.lookup(typed).id == local.id, "failed for #{inspect(typed)}"
      end
    end

    test "tells a stranger on another server from the local one", %{remote: remote} do
      assert Accounts.lookup("alice@remote.example").id == remote.id
      assert Accounts.lookup("@alice@remote.example").id == remote.id
    end

    test "our own domain means our own account, not a namesake", %{local: local} do
      # A handle naming this server is the local account. Reading it as remote
      # would find a different person with the same name.
      assert Accounts.lookup("alice@abuuba.test").id == local.id
    end

    test "finds nothing for nothing" do
      assert Accounts.lookup(nil) == nil
      assert Accounts.lookup("") == nil
      assert Accounts.lookup("nobody@nowhere.example") == nil
    end
  end

  describe "searching for somebody" do
    setup do
      %{
        alice: account_fixture(%{username: "alice", display_name: "Alice Adams"}),
        bob: account_fixture(%{username: "bob", display_name: "Bob Brown"})
      }
    end

    test "matches the start of a username", %{alice: alice} do
      assert [%{id: id}] = Accounts.search("ali")
      assert id == alice.id
    end

    test "matches the start of a display name", %{alice: alice} do
      assert Enum.map(Accounts.search("Alice A"), & &1.id) == [alice.id]
    end

    test "ignores a leading at sign, which is how people type a handle", %{alice: alice} do
      assert Enum.map(Accounts.search("@alice"), & &1.id) == [alice.id]
    end

    test "leaves out somebody a moderator suspended", %{alice: alice} do
      {:ok, _} = Accounts.update_moderation(alice, %{suspended_at: DateTime.utc_now()})

      assert Accounts.search("alice") == []
    end

    test "takes wildcards literally", %{alice: _alice} do
      # `%` is a wildcard in LIKE, so without escaping this matches everybody.
      account_fixture(%{username: "hundred", display_name: "100% sure"})

      assert Accounts.search("%") == []
      assert [%{display_name: "100% sure"}] = Accounts.search("100%")
    end

    test "finds nothing for nothing" do
      assert Accounts.search(nil) == []
      assert Accounts.search("   ") == []
    end

    test "can be asked for local accounts only" do
      remote_account_fixture(%{username: "alicia", domain: "remote.example"})

      assert Accounts.search("ali", local: true) |> Enum.all?(&is_nil(&1.domain))
    end

    test "puts the closest match first" do
      # Somebody half-typing a name wants the shortest thing that matches.
      account_fixture(%{username: "al"})
      account_fixture(%{username: "alexander"})

      assert ["al" | _] = Enum.map(Accounts.search("al"), & &1.username)
    end
  end

  describe "the public directory" do
    test "lists only accounts that asked to be listed" do
      shown = account_fixture(%{username: "shown", discoverable: true})
      account_fixture(%{username: "hidden", discoverable: false})

      assert Enum.map(Accounts.directory(), & &1.id) == [shown.id]
    end

    test "lists nobody from another server" do
      # A directory of everybody this server has heard of is a directory of the
      # fediverse, and nobody elsewhere agreed to appear in ours.
      remote_account_fixture(%{
        username: "elsewhere",
        domain: "remote.example",
        discoverable: true
      })

      assert Accounts.directory() == []
    end

    test "leaves out the suspended" do
      account = account_fixture(%{discoverable: true})
      {:ok, _} = Accounts.update_moderation(account, %{suspended_at: DateTime.utc_now()})

      assert Accounts.directory() == []
    end

    test "leaves out the limited" do
      # Limiting an account says it should not be put in front of people who
      # did not ask for it, and a directory is exactly that. Every other place
      # that offers accounts unasked -- suggestions, trends, the admin's
      # popular list -- already left them out; this one did not.
      account = account_fixture(%{discoverable: true})
      {:ok, _} = Accounts.update_moderation(account, %{silenced_at: DateTime.utc_now()})

      assert Accounts.directory() == []
    end

    test "leaves out somebody who has moved" do
      # The column is set directly because what is under test is the listing,
      # not the migration that writes it.
      arrived = account_fixture(%{discoverable: true})
      departed = account_fixture(%{discoverable: true})

      {:ok, _} =
        departed
        |> Ecto.Changeset.change(moved_to_account_id: arrived.id)
        |> Abuuba.Repo.update()

      assert Enum.map(Accounts.directory(), & &1.id) == [arrived.id]
    end
  end

  describe "the lists a client shows" do
    setup do
      %{account: account_fixture(), other: account_fixture()}
    end

    test "who you blocked", %{account: account, other: other} do
      {:ok, _} = Relationships.block(account, other)

      assert Enum.map(Relationships.blocked_accounts(account), & &1.id) == [other.id]
      assert Relationships.blocked_accounts(other) == []
    end

    test "who you muted, minus the mutes that have run out", %{account: account, other: other} do
      # A mute with a duration is over when it is over, and a list that still
      # showed it would have somebody unmuting what is no longer muted.
      {:ok, _} =
        Relationships.mute(account, other, %{
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert Relationships.muted_accounts(account) == []

      third = account_fixture()
      {:ok, _} = Relationships.mute(account, third, %{})

      assert Enum.map(Relationships.muted_accounts(account), & &1.id) == [third.id]
    end

    test "which domains you blocked", %{account: account} do
      {:ok, _} = Relationships.block_domain(account, "noisy.example")

      assert Relationships.blocked_domains(account) == ["noisy.example"]
    end

    test "who is waiting to follow you", %{account: account, other: other} do
      {:ok, _} = Relationships.request_follow(other, account)

      assert Enum.map(Relationships.pending_followers(account), & &1.id) == [other.id]
      assert Relationships.pending_followers(other) == []
    end

    test "your followers and who you follow", %{account: account, other: other} do
      {:ok, _} = Relationships.follow(other, account)

      assert Enum.map(Relationships.followers(account), & &1.id) == [other.id]
      assert Enum.map(Relationships.following(other), & &1.id) == [account.id]
    end
  end

  describe "removing a follower" do
    test "stops them following without telling them why" do
      # Quieter than a block, which would also stop them reading anything at
      # all. That is a different and much louder thing to do to somebody.
      account = account_fixture()
      follower = account_fixture()
      {:ok, _} = Relationships.follow(follower, account)

      assert :ok = Relationships.remove_follower(account, follower)

      refute Relationships.following?(follower, account)
      refute Relationships.blocking?(account, follower)
    end
  end

  describe "familiar followers" do
    test "answers who that you follow also follows a stranger" do
      # The useful answer to "who is this, and does anybody I trust know them?"
      me = account_fixture()
      friend = account_fixture()
      stranger = account_fixture()

      {:ok, _} = Relationships.follow(me, friend)
      {:ok, _} = Relationships.follow(friend, stranger)

      assert [{id, [%{id: friend_id}]}] = Relationships.familiar_followers(me, [stranger.id])
      assert id == stranger.id
      assert friend_id == friend.id
    end

    test "answers nothing where nobody you follow does" do
      me = account_fixture()
      stranger = account_fixture()

      assert [{_id, []}] = Relationships.familiar_followers(me, [stranger.id])
    end
  end
end
