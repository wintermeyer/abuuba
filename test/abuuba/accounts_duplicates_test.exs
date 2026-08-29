defmodule Abuuba.AccountsDuplicatesTest do
  @moduledoc """
  Finding the duplicates `merge` already knows how to join.

  The detector has to agree with `Merge.same_key?/2`, which is what `merge`
  refuses to proceed without. That function compares each account's *latest
  non-revoked* key, so grouping on the keypairs table directly would report an
  account holding two live keys as a duplicate of itself, and would miss a pair
  whose match is only on their current keys. A detector that disagrees with the
  thing that acts on it sends an admin to merge accounts the merge will refuse.
  """

  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Merge
  alias Abuuba.Repo

  describe "duplicates/0" do
    test "says nothing when every remote account has its own key" do
      remote_with_key("alice@one.example", "KEY-A")
      remote_with_key("bob@two.example", "KEY-B")

      assert Merge.duplicates() == []
    end

    test "finds two accounts signing with the same key" do
      one = remote_with_key("alice@old.example", "SHARED")
      two = remote_with_key("alice@new.example", "SHARED")

      assert [group] = Merge.duplicates()
      assert Enum.map(group, & &1.id) |> Enum.sort() == Enum.sort([one.id, two.id])
    end

    test "and agrees with the check merge gates on" do
      one = remote_with_key("alice@old.example", "SHARED")
      two = remote_with_key("alice@new.example", "SHARED")

      assert [[first, second]] = Merge.duplicates()
      assert Merge.same_key?(first, second)
      assert Merge.same_key?(one, two)
    end

    test "leaves local accounts out of it" do
      # Two local accounts sharing a key would be this server's own bug, and
      # merging them is refused outright anyway.
      local_with_key("mine", "SHARED")
      local_with_key("also_mine", "SHARED")

      assert Merge.duplicates() == []
    end

    test "ignores a revoked key" do
      remote_with_key("alice@old.example", "SHARED", revoked: true)
      remote_with_key("alice@new.example", "SHARED")

      assert Merge.duplicates() == []
    end

    # The trap this test exists for: grouping on `keypairs` rather than on each
    # account's latest key would pair this account with itself.
    test "does not report one account holding two live keys" do
      account = remote_with_key("alice@one.example", "OLD-BUT-LIVE")
      add_key(account, "CURRENT")

      assert Merge.duplicates() == []
    end

    test "matches on the current key, not a superseded one" do
      one = remote_with_key("alice@old.example", "WAS-SHARED")
      two = remote_with_key("alice@new.example", "SOMETHING-ELSE")

      add_key(one, "NOW-SHARED")
      add_key(two, "NOW-SHARED")

      assert [group] = Merge.duplicates()
      assert length(group) == 2
    end

    test "reports three of them as one group" do
      for host <- ~w(one two three) do
        remote_with_key("alice@#{host}.example", "SHARED")
      end

      assert [group] = Merge.duplicates()
      assert length(group) == 3
    end
  end

  defp remote_with_key(handle, key, opts \\ []) do
    [username, domain] = String.split(handle, "@")

    account = account_fixture(%{username: username, domain: domain})
    add_key(account, key, opts)
    account
  end

  defp local_with_key(username, key) do
    account = account_fixture(%{username: username})
    add_key(account, key)
    account
  end

  defp add_key(account, key, opts \\ []) do
    now = DateTime.utc_now()
    revoked = if Keyword.get(opts, :revoked, false), do: now

    Repo.insert_all("keypairs", [
      %{
        account_id: account.id,
        public_key: key,
        private_key: nil,
        revoked_at: revoked,
        inserted_at: now,
        updated_at: now
      }
    ])

    account
  end
end
