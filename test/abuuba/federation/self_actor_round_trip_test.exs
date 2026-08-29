defmodule Abuuba.Federation.SelfActorRoundTripTest do
  @moduledoc """
  A profile this server publishes, read back by this server's own parser.

  The companion of `Abuuba.Federation.SelfRoundTripTest`, which found that a post
  federated with no language because the serializer never wrote the one field
  the parser reads it from. A profile carries more of that kind of field than a
  post does -- the flags, the fields somebody put on their own profile, the key
  every signature is checked against -- and the same two halves had never been
  pointed at each other.

  The document is transplanted onto a remote host before being read back,
  because a server will not accept its own actor as somebody else's.
  """
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.ResolveActor
  alias Abuuba.Federation.Signature

  @remote "remote.example"

  # Exactly what `GET /ap/users/:name` answers, addressed as if it came from
  # the peer.
  defp as_peer(account) do
    remote_id = "https://#{@remote}/users/#{account.username}"

    account
    |> Actor.render()
    |> Map.put("id", remote_id)
    |> Map.put("url", "https://#{@remote}/@#{account.username}")
    |> Map.put("inbox", remote_id <> "/inbox")
    |> Map.put("outbox", remote_id <> "/outbox")
    |> Map.put("followers", remote_id <> "/followers")
    |> Map.put("following", remote_id <> "/following")
    |> Map.update("publicKey", nil, fn key ->
      key && Map.put(key, "id", remote_id <> "#main-key")
    end)
  end

  defp read_back(account) do
    document = as_peer(account)

    ResolveActor.resolve(document["id"],
      fetch: fn _uri -> {:ok, document} end,
      verify_loopback: false
    )
  end

  describe "a profile this server publishes" do
    test "comes back with what a person wrote about themselves" do
      account =
        account_fixture(%{
          username: "gardener",
          display_name: "The Gardener",
          note: "I grow things."
        })

      assert {:ok, stored} = read_back(account)

      assert stored.display_name == "The Gardener"
      assert stored.note =~ "I grow things"
      assert stored.username == "gardener"
      assert stored.domain == @remote
    end

    test "and the flags a person set" do
      account =
        account_fixture(%{
          username: "careful",
          locked: true,
          discoverable: true,
          indexable: false,
          actor_type: :service
        })

      assert {:ok, stored} = read_back(account)

      assert stored.locked, "a locked account came back unlocked, so follows would auto-accept"
      assert stored.discoverable
      refute stored.indexable
      assert stored.bot
    end

    test "and the sites allowed to name them as an author" do
      # The server that shows a link preview is the one that has to check the
      # claim, and it is never the author's own -- so the list has to travel or
      # it protects nobody outside this instance.
      account = account_fixture(%{username: "columnist"})

      {:ok, account} =
        Abuuba.Accounts.update_profile(account, %{
          "attribution_domains" => ["https://news.example/", "*.blog.example"]
        })

      assert {:ok, stored} = read_back(account)

      assert stored.attribution_domains == ["news.example", "blog.example"]
    end

    test "and that an account is a memorial" do
      # A moderator's decision rather than the person's, and the one flag of
      # the set that never crossed the wire: the document did not carry it and
      # the resolver did not look for it, so somebody's memorial page arrived
      # everywhere else as an ordinary account.
      account = account_fixture(%{username: "remembered"})
      {:ok, account} = Abuuba.Accounts.update_moderation(account, %{memorial: true})

      assert {:ok, stored} = read_back(account)

      assert stored.memorial
    end

    test "and the fields on their profile" do
      {:ok, account} =
        account_fixture(%{username: "linker"})
        |> Accounts.update_profile(%{
          "fields" => [
            %{"name" => "Web", "value" => "https://example.com"},
            %{"name" => "Job", "value" => "Gardener"}
          ]
        })

      assert {:ok, stored} = read_back(account)

      assert Enum.map(stored.fields, & &1.name) == ["Web", "Job"]
      assert Enum.map(stored.fields, & &1.value) == ["https://example.com", "Gardener"]
    end

    test "and the key every signature from it is checked against" do
      account = account_fixture(%{username: "signer"})

      assert {:ok, stored} = read_back(account)

      assert Signature.public_key_of(stored),
             "the key did not survive, so nothing this account signs could be verified"
    end
  end
end
