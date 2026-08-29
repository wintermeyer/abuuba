defmodule Abuuba.Federation.LocalUriResolutionTest do
  @moduledoc """
  Reading one of our own URIs back into the row it names.

  A local account and a local post have no `uri` column: the id this server
  publishes is derived from the row, which is what keeps it from having to be
  written twice and kept in step. The cost is that a URI cannot be looked up in
  a column, and for a while every lookup tried to, so nothing a peer addressed
  to somebody here could be found.
  """

  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Federation.Activity
  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Serializer
  alias Abuuba.Federation.URIs
  alias Abuuba.Relationships
  alias Abuuba.Statuses

  describe "parsing one of our URIs" do
    test "an account, in the username scheme" do
      assert {:account, "alice"} = URIs.parse_local("#{URIs.base_url()}/users/alice")
    end

    test "an account, in the numeric scheme" do
      assert {:account_id, 42} = URIs.parse_local("#{URIs.base_url()}/ap/users/42")
    end

    test "a post" do
      assert {:status, 7} = URIs.parse_local("#{URIs.base_url()}/users/alice/statuses/7")
      assert {:status, 7} = URIs.parse_local("#{URIs.base_url()}/ap/users/1/statuses/7")
    end

    test "the activity wrapper names the post it carried" do
      # A peer that stored the delivery's id rather than the object's comes
      # back with this one, and it is asking about the same post.
      assert {:status, 7} =
               URIs.parse_local("#{URIs.base_url()}/users/alice/statuses/7/activity")
    end

    test "a fragment names a part of a document, not another document" do
      assert {:account, "alice"} = URIs.parse_local("#{URIs.base_url()}/users/alice#main-key")
    end

    test "anything on another host is not ours to read" do
      assert :error = URIs.parse_local("https://peer.example/users/alice")
      assert :error = URIs.parse_local("https://peer.example/users/alice/statuses/1")
    end

    test "a shape this server never hands out" do
      assert :error = URIs.parse_local("#{URIs.base_url()}/nonsense")
      assert :error = URIs.parse_local("#{URIs.base_url()}/users/alice/statuses/not-a-number")
      assert :error = URIs.parse_local("#{URIs.base_url()}/ap/users/not-a-number")
      assert :error = URIs.parse_local("not a uri at all")
      assert :error = URIs.parse_local(nil)
    end

    test "a host that merely starts the same is not ours" do
      # `abuuba.test.evil.example` must not be read as `abuuba.test`, or a stranger
      # picks the account any inbound activity resolves to.
      assert :error = URIs.parse_local("https://#{URIs.local_host()}.evil.example/users/alice")
    end
  end

  describe "finding the row" do
    test "an account by the URI this server publishes for it" do
      account = account_fixture(%{username: "alice"})

      assert Helpers.local_account(Actor.id(account)).id == account.id
    end

    test "an account on the numeric scheme" do
      account = account_fixture(%{username: "numbered", id_scheme: :numeric})

      assert Helpers.local_account(Actor.id(account)).id == account.id
    end

    test "a post by the URI every activity about it names" do
      account = account_fixture(%{username: "alice"})
      status = status_fixture(%{account_id: account.id})

      found = Statuses.get_status_unchecked_by_uri(Serializer.status_uri(status, account))

      assert found.id == status.id
    end

    test "a post by the id of the activity that carried it" do
      account = account_fixture(%{username: "alice"})
      status = status_fixture(%{account_id: account.id})
      activity_uri = Serializer.status_uri(status, account) <> "/activity"

      assert Statuses.get_status_unchecked_by_uri(activity_uri).id == status.id
    end

    test "a post from another server still comes out of its column" do
      remote =
        remote_account_fixture(%{domain: "peer.example", uri: "https://peer.example/users/bob"})

      status =
        status_fixture(%{account_id: remote.id, local: false, uri: "https://peer.example/s/1"})

      assert Statuses.get_status_unchecked_by_uri("https://peer.example/s/1").id == status.id
    end

    test "a local URI naming an account is not a post" do
      account = account_fixture(%{username: "alice"})

      assert Statuses.get_status_unchecked_by_uri(Actor.id(account)) == nil
    end

    test "a local URI naming nobody is nobody" do
      assert Helpers.local_account("#{URIs.base_url()}/users/ghost") == nil
      assert Statuses.get_status_unchecked_by_uri("#{URIs.base_url()}/users/a/statuses/1") == nil
    end

    test "a remote account is not served up as a local one" do
      remote_account_fixture(%{username: "impostor", domain: "peer.example"})

      # Their username happens to match a path shape of ours. It is still not
      # an account here.
      assert Helpers.local_account("#{URIs.base_url()}/users/impostor") == nil
    end
  end

  describe "what this unblocks" do
    setup do
      target = account_fixture(%{username: "target"})

      follower =
        remote_account_fixture(%{
          username: "far",
          domain: "peer.example",
          uri: "https://peer.example/users/far",
          inbox_url: "https://peer.example/users/far/inbox"
        })

      %{target: target, follower: follower}
    end

    test "a remote server can follow somebody here", %{target: target, follower: follower} do
      activity = %{
        "id" => "https://peer.example/activities/1",
        "type" => "Follow",
        "actor" => follower.uri,
        "object" => Actor.id(target)
      }

      Activity.Follow.handle(activity, actor: follower)

      assert Relationships.following?(follower, target)
    end

    test "a remote server can favourite a post here", %{target: target, follower: follower} do
      status = status_fixture(%{account_id: target.id})

      activity = %{
        "id" => "https://peer.example/activities/2",
        "type" => "Like",
        "actor" => follower.uri,
        "object" => Serializer.status_uri(status, target)
      }

      Activity.Like.handle(activity, actor: follower)

      assert Statuses.favourited?(follower.id, status.id)
    end

    test "a remote server can block somebody here", %{target: target, follower: follower} do
      activity = %{
        "id" => "https://peer.example/activities/3",
        "type" => "Block",
        "actor" => follower.uri,
        "object" => Actor.id(target)
      }

      Activity.Block.handle(activity, actor: follower)

      assert Relationships.blocking?(follower, target)
    end
  end
end
