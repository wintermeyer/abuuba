defmodule Abuuba.Federation.FollowerSyncTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.FollowerSync
  alias Abuuba.Relationships

  defp remote(username, domain) do
    remote_account_fixture(%{
      username: username,
      domain: domain,
      uri: "https://#{domain}/users/#{username}"
    })
  end

  describe "the digest" do
    test "does not depend on the order of the list" do
      # Any hash of a concatenated list would need both sides to agree on an
      # ordering, and they never will.
      uris = ["https://a.example/1", "https://b.example/2", "https://c.example/3"]

      assert FollowerSync.digest(uris) == FollowerSync.digest(Enum.reverse(uris))
      assert FollowerSync.digest(uris) == FollowerSync.digest(Enum.shuffle(uris))
    end

    test "returns to where it started when a follower is added and removed" do
      uris = ["https://a.example/1", "https://b.example/2"]
      added = ["https://c.example/3" | uris]

      refute FollowerSync.digest(uris) == FollowerSync.digest(added)

      assert FollowerSync.digest(uris) ==
               FollowerSync.digest(added -- ["https://c.example/3"])
    end

    test "differs for different sets" do
      assert FollowerSync.digest(["https://a.example/1"]) !=
               FollowerSync.digest(["https://a.example/2"])
    end

    test "an empty list has a stable value" do
      assert FollowerSync.digest([]) == String.duplicate("0", 64)
    end
  end

  describe "the header" do
    test "covers only the followers on the domain being told" do
      # A peer is allowed to ask about its own followers and nobody else's.
      author = account_fixture()

      {:ok, _} = Relationships.follow(remote("bob", "one.example"), author)
      {:ok, _} = Relationships.follow(remote("carol", "two.example"), author)

      assert FollowerSync.follower_uris_on(author, "one.example") ==
               ["https://one.example/users/bob"]

      header = FollowerSync.header(author, "one.example")

      assert header =~ ~s(collectionId="#{Actor.followers_id(author)}")
      assert header =~ FollowerSync.digest(["https://one.example/users/bob"])
    end

    test "points at the collection that answers it" do
      # A peer that is sent one address and served another resyncs forever.
      author = account_fixture()

      assert FollowerSync.header(author, "one.example") =~
               ~s(url="#{Actor.followers_id(author)}?domain=one.example")
    end

    test "is not confused by how a domain was capitalised" do
      author = account_fixture()
      {:ok, _} = Relationships.follow(remote("bob", "one.example"), author)

      assert FollowerSync.follower_uris_on(author, "One.Example") ==
               ["https://one.example/users/bob"]
    end
  end

  describe "digests worked out in one pass" do
    test "agree with asking about each domain separately" do
      # Distribution computes every destination's digest from the follower list
      # it already loaded. If that ever disagreed with the query the endpoint
      # runs, every private post would trigger a resync that never converges.
      author = account_fixture()

      for {name, domain} <- [
            {"bob", "one.example"},
            {"carol", "one.example"},
            {"dan", "two.example"}
          ] do
        {:ok, _} = Relationships.follow(remote(name, domain), author)
      end

      followers =
        for domain <- ~w(one.example two.example),
            uri <- FollowerSync.follower_uris_on(author, domain),
            do: %{domain: domain, uri: uri}

      by_domain = FollowerSync.digests_by_domain(followers)

      for domain <- ~w(one.example two.example) do
        expected = author |> FollowerSync.follower_uris_on(domain) |> FollowerSync.digest()

        assert by_domain[domain] == expected
      end
    end

    test "ignores local accounts, which have no domain" do
      assert FollowerSync.digests_by_domain([%{domain: nil, uri: "https://here.example/u/a"}]) ==
               %{}
    end

    test "does not mind how a domain was capitalised" do
      followers = [
        %{domain: "One.Example", uri: "https://one.example/users/bob"},
        %{domain: "one.example", uri: "https://one.example/users/carol"}
      ]

      assert Map.keys(FollowerSync.digests_by_domain(followers)) == ["one.example"]
    end
  end
end
