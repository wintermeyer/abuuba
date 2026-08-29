defmodule Abuuba.Accounts.MigrationTest do
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Migration
  alias Abuuba.Federation.Actor
  alias Abuuba.Relationships
  alias Abuuba.Repo

  setup do
    account = account_fixture()
    follower = account_fixture()

    {:ok, _follow} = Relationships.follow(follower, account)

    %{account: account, follower: follower}
  end

  defp elsewhere(account, opts \\ []) do
    aliases = Keyword.get(opts, :also_known_as, [Actor.id(account)])

    account_fixture(%{
      username: "elsewhere#{System.unique_integer([:positive])}",
      domain: "other.example",
      uri: "https://other.example/users/elsewhere#{System.unique_integer([:positive])}",
      also_known_as: aliases
    })
  end

  defp move(account, target, opts \\ []) do
    # The handle resolves to an account already here, so no server is asked.
    handle = "#{target.username}@#{target.domain}"

    Migration.move(account, handle, Keyword.put_new(opts, :announce, false))
  end

  describe "moving away" do
    test "points the account at the new one", %{account: account} do
      target = elsewhere(account)

      assert {:ok, moved} = move(account, target)

      assert moved.moved_to_account_id == target.id
      refute is_nil(moved.moved_at)
    end

    test "and brings the followers on this server with it", %{
      account: account,
      follower: follower
    } do
      # The followers here are this server's to move. Everybody else's server
      # gets the activity and decides for itself.
      target = elsewhere(account)

      {:ok, _moved} = move(account, target)

      assert Relationships.following?(follower, target)
      refute Relationships.following?(follower, account)
    end

    test "refuses an account that does not claim this one back", %{account: account} do
      # Without the backlink anybody could name any account as their
      # destination and be handed a follower list.
      target = elsewhere(account, also_known_as: [])

      assert {:error, :no_backlink} = move(account, target)
      assert is_nil(Repo.reload(account).moved_to_account_id)
    end

    test "refuses a second move inside the cooldown", %{account: account} do
      # Moving repeatedly is how a follower list is walked across the network
      # faster than anybody can notice.
      first = elsewhere(account)
      {:ok, moved} = move(account, first)

      second = elsewhere(moved)

      assert {:error, :moved_too_recently} = move(moved, second)
    end

    test "and allows one after it has passed", %{account: account} do
      target = elsewhere(account)
      long_ago = DateTime.add(DateTime.utc_now(), -(Migration.cooldown_days() + 1), :day)

      {:ok, account} = Accounts.update_account(account, %{moved_at: long_ago})

      assert {:ok, _moved} = move(account, target)
    end

    test "refuses moving to itself", %{account: account} do
      {:ok, account} =
        Accounts.update_account(account, %{also_known_as: [Actor.id(account)]})

      assert {:error, :same_account} =
               Migration.move(account, account.username, announce: false)
    end

    test "refuses an account nobody can find", %{account: account} do
      assert {:error, :unknown_account} =
               Migration.move(account, "nobody@gone.example", announce: false)
    end
  end

  describe "coming back" do
    test "clears the pointer other servers read", %{account: account} do
      target = elsewhere(account)
      {:ok, moved} = move(account, target)

      assert {:ok, back} = Migration.cancel(moved)

      assert is_nil(back.moved_to_account_id)
    end

    test "but not the cooldown, because coming back is not another move", %{account: account} do
      target = elsewhere(account)
      {:ok, moved} = move(account, target)
      {:ok, back} = Migration.cancel(moved)

      refute Migration.movable?(back)
    end
  end

  describe "the morning after" do
    test "every waiting follow request can be accepted at once", %{account: account} do
      # Each follower's server acts on the Move at the same moment, so an
      # account that approves by hand faces a thousand requests it already
      # agreed to years ago.
      {:ok, locked} = Accounts.update_account(account, %{locked: true})

      for _each <- 1..3 do
        {:ok, _request} = Relationships.request_follow(account_fixture(), locked)
      end

      assert Relationships.accept_all_follow_requests(locked) == 3
      assert Relationships.pending_followers(locked) == []
    end
  end
end
