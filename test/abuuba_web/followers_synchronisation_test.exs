defmodule AbuubaWeb.FollowersSynchronisationTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Keypair
  alias Abuuba.Federation.FollowerSync
  alias Abuuba.Federation.Signature
  alias Abuuba.Federation.URIs
  alias Abuuba.Relationships
  alias Abuuba.Repo

  @peer_actor "https://peer.example/users/alice"

  setup do
    %{public_key: public, private_key: private} = Keypair.generate()

    peer =
      remote_account_fixture(%{username: "alice", domain: "peer.example", uri: @peer_actor})

    {:ok, _keypair} =
      Repo.insert(%Keypair{account_id: peer.id, public_key: public, type: :rsa_2048})

    author = account_fixture(%{username: "author"})
    {:ok, _} = Relationships.follow(peer, author)

    %{author: author, peer: peer, private: private}
  end

  defp fetch(conn, path, opts \\ []) do
    url = URIs.base_url() <> path

    case Keyword.get(opts, :sign_with) do
      nil ->
        get(conn, path)

      private ->
        {:ok, headers} =
          Signature.sign(
            method: :get,
            url: url,
            key_id: Keyword.get(opts, :key_id, @peer_actor <> "#main-key"),
            private_key: private
          )

        conn |> apply_signed_headers(headers) |> get(path)
    end
  end

  describe "the partial collection" do
    test "tells a peer which of its own accounts follow ours", %{conn: conn, private: private} do
      conn = fetch(conn, "/users/author/followers?domain=peer.example", sign_with: private)

      assert %{"type" => "OrderedCollection", "orderedItems" => items} = json_response(conn, 200)
      assert items == [@peer_actor]
    end

    test "names itself and what it is part of", %{conn: conn, private: private} do
      conn = fetch(conn, "/users/author/followers?domain=peer.example", sign_with: private)

      body = json_response(conn, 200)

      assert body["id"] == "#{URIs.base_url()}/users/author/followers?domain=peer.example"
      assert body["partOf"] == "#{URIs.base_url()}/users/author/followers"
    end

    test "matches the digest the delivery header carried", %{
      conn: conn,
      author: author,
      private: private
    } do
      # The whole mechanism is that a peer compares its own digest with ours.
      # If the collection it then fetches disagrees with the digest we sent,
      # the peer resyncs forever and never converges.
      conn = fetch(conn, "/users/author/followers?domain=peer.example", sign_with: private)

      items = json_response(conn, 200)["orderedItems"]
      header = FollowerSync.header(author, "peer.example")

      assert header =~ FollowerSync.digest(items)
    end

    test "is at the address the delivery header sent the peer to", %{
      conn: conn,
      author: author,
      private: private
    } do
      header = FollowerSync.header(author, "peer.example")
      [_, url] = Regex.run(~r/url="([^"]+)"/, header)

      conn = fetch(conn, String.replace_prefix(url, URIs.base_url(), ""), sign_with: private)

      assert json_response(conn, 200)["orderedItems"] == [@peer_actor]
    end

    test "leaves out followers on other servers", %{conn: conn, author: author, private: private} do
      other = remote_account_fixture(%{username: "bob", domain: "other.example"})
      {:ok, _} = Relationships.follow(other, author)

      conn = fetch(conn, "/users/author/followers?domain=peer.example", sign_with: private)

      assert json_response(conn, 200)["orderedItems"] == [@peer_actor]
    end
  end

  describe "who may ask" do
    test "nobody, unsigned", %{conn: conn} do
      conn = fetch(conn, "/users/author/followers?domain=peer.example")

      assert conn.status == 401
    end

    test "not a server asking about a domain that is not its own", %{conn: conn, private: private} do
      # A peer is entitled to know about its own users and nobody else's.
      conn = fetch(conn, "/users/author/followers?domain=other.example", sign_with: private)

      assert conn.status == 403
    end

    test "not with a signature we cannot verify", %{conn: conn} do
      %{private_key: stranger} = Keypair.generate()

      conn =
        fetch(conn, "/users/author/followers?domain=peer.example",
          sign_with: stranger,
          key_id: "https://nowhere.example/users/nobody#main-key"
        )

      assert conn.status in [401, 403, 503]
    end

    test "a domain that is not a string is not a domain", %{conn: conn, private: private} do
      # `?domain[]=x` reaches the controller as a list. Downcasing one raises,
      # which turns a stranger's malformed query into a 500.
      conn = fetch(conn, "/users/author/followers?domain[]=peer.example", sign_with: private)

      assert conn.status == 200
      assert json_response(conn, 200)["type"] == "OrderedCollection"
      refute json_response(conn, 200)["partOf"]
    end

    test "an account nobody here has is still just missing", %{conn: conn, private: private} do
      conn = fetch(conn, "/users/nobody/followers?domain=peer.example", sign_with: private)

      assert conn.status == 404
    end
  end

  describe "the ordinary followers collection" do
    test "is unchanged and still needs no signature", %{conn: conn} do
      conn = fetch(conn, "/users/author/followers")

      assert %{"type" => "OrderedCollection", "totalItems" => 1} = json_response(conn, 200)
    end
  end
end
