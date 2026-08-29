defmodule AbuubaWeb.ActivityPubObjectsTest do
  @moduledoc """
  The addresses abuuba puts inside the documents it federates.

  Every post leaves here naming itself `<actor>/statuses/<id>`, and a peer
  stores that string and comes back to it: to thread a reply it received out of
  order, to act on an `Announce` that carried a bare URI, to check a quote. A
  404 there is not a missing page, it is every one of those failing quietly on
  somebody else's server.
  """

  # Not async: the visibility tests reach the instance actor while verifying a
  # signature, and it is a singleton at a fixed id.
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Keypair
  alias Abuuba.Federation.Serializer
  alias Abuuba.Federation.Signature
  alias Abuuba.Federation.URIs
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Statuses

  @peer_actor "https://peer.example/users/stranger"

  defp document(conn), do: json_response(conn, 200)

  # A peer with a key we can check, so a signed fetch can be made in a test.
  defp peer_with_key(username) do
    %{public_key: public, private_key: private} = Keypair.generate()

    peer =
      remote_account_fixture(%{
        username: username,
        domain: "peer.example",
        uri: "https://peer.example/users/#{username}"
      })

    {:ok, _keypair} =
      Repo.insert(%Keypair{account_id: peer.id, public_key: public, type: :rsa_2048})

    {peer, private}
  end

  defp signed_get(conn, path, key_id, private_key) do
    {:ok, headers} =
      Signature.sign(
        method: :get,
        url: URIs.base_url() <> path,
        key_id: key_id,
        private_key: private_key
      )

    conn |> apply_signed_headers(headers) |> get(path)
  end

  describe "a post at the id abuuba hands out" do
    setup do
      account = account_fixture(%{username: "alice"})
      %{account: account}
    end

    test "is served where the serializer said it would be", %{conn: conn, account: account} do
      status = status_fixture(%{account_id: account.id, text: "hello world"})
      uri = Serializer.status_uri(status, account)

      # Not a hand-written path: the assertion is that the address inside every
      # document we federate resolves, so the test has to fetch that address.
      assert uri == "#{URIs.base_url()}/users/alice/statuses/#{status.id}"

      body = conn |> get(URI.parse(uri).path) |> document()

      assert body["id"] == uri
      assert body["type"] == "Note"
      assert body["content"] =~ "hello world"
      assert body["attributedTo"] == "#{URIs.base_url()}/users/alice"
    end

    test "points readers at the page, not at the document", %{conn: conn, account: account} do
      # `url` is where a peer sends somebody who clicked "open original". It
      # fell back to the id, so every one of them landed on JSON.
      status = status_fixture(%{account_id: account.id})

      body = conn |> get(~p"/users/alice/statuses/#{status.id}") |> document()

      assert body["url"] == URIs.status_url(account, status.id)
      assert body["url"] != body["id"]
    end

    test "is served as activity+json, which is how a peer recognises it", %{
      conn: conn,
      account: account
    } do
      status = status_fixture(%{account_id: account.id})

      conn = get(conn, ~p"/users/alice/statuses/#{status.id}")

      assert conn |> get_resp_header("content-type") |> hd() =~ "application/activity+json"
    end

    test "is wrapped in the Create that carried it", %{conn: conn, account: account} do
      status = status_fixture(%{account_id: account.id})

      body = conn |> get(~p"/users/alice/statuses/#{status.id}/activity") |> document()

      assert body["type"] == "Create"
      assert body["id"] == Serializer.status_uri(status, account) <> "/activity"
      assert body["object"]["id"] == Serializer.status_uri(status, account)
    end

    test "is wrapped in an Announce when it is a boost", %{conn: conn, account: account} do
      author = account_fixture()
      original = status_fixture(%{account_id: author.id})
      {:ok, boost} = Statuses.boost(account, original)

      body = conn |> get(~p"/users/alice/statuses/#{boost.id}/activity") |> document()

      assert body["type"] == "Announce"
      assert body["object"] == Serializer.status_uri(original, author)
    end

    test "sends a boost's own address on to what it boosted", %{conn: conn, account: account} do
      # A boost has no words of its own, so there is no object at its id worth
      # serving. The reference implementation redirects to the original and
      # peers have been following that for years.
      author = account_fixture(%{username: "author"})
      original = status_fixture(%{account_id: author.id})
      {:ok, boost} = Statuses.boost(account, original)

      conn = get(conn, ~p"/users/alice/statuses/#{boost.id}")

      assert redirected_to(conn, 302) == URIs.status_url(author, original.id)
    end

    test "is answered on the numeric scheme with the canonical address", %{
      conn: conn,
      account: account
    } do
      status = status_fixture(%{account_id: account.id})

      conn = get(conn, ~p"/ap/users/#{account.id}/statuses/#{status.id}")

      assert conn.status == 301
      assert get_resp_header(conn, "location") == [Serializer.status_uri(status, account)]
    end
  end

  describe "what is not served" do
    setup do
      account = account_fixture(%{username: "alice"})
      %{account: account}
    end

    test "a post belonging to somebody else, even by the right id", %{conn: conn} do
      other = account_fixture()
      status = status_fixture(%{account_id: other.id})

      assert conn |> get(~p"/users/alice/statuses/#{status.id}") |> json_response(404)
    end

    test "a deleted post", %{conn: conn, account: account} do
      status = status_fixture(%{account_id: account.id})
      {:ok, _deleted} = Statuses.delete_status(status)

      assert conn |> get(~p"/users/alice/statuses/#{status.id}") |> json_response(404)
    end

    test "a post that came from another server", %{conn: conn} do
      remote =
        remote_account_fixture(%{
          username: "bob",
          domain: "peer.example",
          uri: "https://peer.example/users/bob"
        })

      status =
        status_fixture(%{
          account_id: remote.id,
          local: false,
          uri: "https://peer.example/s/1"
        })

      # Serving it would hand out a second id for a post another server already
      # named, and a peer that dereferenced ours would store the copy.
      assert conn |> get(~p"/users/bob/statuses/#{status.id}") |> json_response(404)
    end

    test "an id that is not a number", %{conn: conn} do
      assert conn |> get(~p"/users/alice/statuses/not-a-number") |> json_response(404)
    end

    test "an id too large to be one", %{conn: conn} do
      # A number Postgres cannot hold. Handed straight to the query it raises
      # rather than missing, which turns a typo in somebody's crawler into a
      # stream of 500s in our logs.
      assert conn
             |> get(~p"/users/alice/statuses/99999999999999999999999999")
             |> json_response(404)
    end

    test "an account id too large to be one", %{conn: conn} do
      assert conn |> get(~p"/ap/users/99999999999999999999999999") |> json_response(404)
    end

    test "anything belonging to a suspended account", %{conn: conn} do
      suspended =
        account_fixture(%{username: "banned", suspended_at: DateTime.utc_now(:microsecond)})

      status = status_fixture(%{account_id: suspended.id})

      assert conn |> get(~p"/users/banned/statuses/#{status.id}") |> json_response(404)
    end
  end

  describe "visibility" do
    setup do
      author = account_fixture(%{username: "alice"})
      {peer, private} = peer_with_key("stranger")

      %{author: author, peer: peer, private: private}
    end

    test "a follower of the author may fetch a followers-only post", %{
      conn: conn,
      author: author,
      peer: peer,
      private: private
    } do
      # The positive control for the two refusals below. Without it a broken
      # signature path would make every refusal pass while proving nothing.
      {:ok, _follow} = Relationships.follow(peer, author)
      status = status_fixture(%{account_id: author.id, visibility: :private})
      path = "/users/alice/statuses/#{status.id}"

      body =
        conn
        |> signed_get(path, @peer_actor <> "#main-key", private)
        |> document()

      assert body["id"] == Serializer.status_uri(status, author)
    end

    test "a stranger may not fetch a followers-only post", %{
      conn: conn,
      author: author,
      private: private
    } do
      status = status_fixture(%{account_id: author.id, visibility: :private})
      path = "/users/alice/statuses/#{status.id}"

      assert conn
             |> signed_get(path, @peer_actor <> "#main-key", private)
             |> json_response(404)
    end

    test "nobody unsigned may fetch a followers-only post", %{conn: conn, author: author} do
      status = status_fixture(%{account_id: author.id, visibility: :private})

      assert conn |> get(~p"/users/alice/statuses/#{status.id}") |> json_response(404)
    end

    test "somebody a direct post names may fetch it", %{
      conn: conn,
      author: author,
      peer: peer,
      private: private
    } do
      status = status_fixture(%{account_id: author.id, visibility: :direct})
      {:ok, _mention} = Statuses.mention(status, peer)
      path = "/users/alice/statuses/#{status.id}"

      body =
        conn
        |> signed_get(path, @peer_actor <> "#main-key", private)
        |> document()

      assert body["id"] == Serializer.status_uri(status, author)
    end

    test "an unlisted post is public to fetch, which is what unlisted means", %{
      conn: conn,
      author: author
    } do
      status = status_fixture(%{account_id: author.id, visibility: :unlisted})

      body = conn |> get(~p"/users/alice/statuses/#{status.id}") |> document()

      assert body["id"] == Serializer.status_uri(status, author)
    end
  end

  describe "the outbox" do
    test "names posts by the id abuuba hands out", %{conn: conn} do
      # A local status has no `uri` column: the id is derived. Reading the
      # column straight out filled the outbox with nulls, and a peer walking it
      # got a collection of nothing it could fetch.
      account = account_fixture(%{username: "alice"})
      status = status_fixture(%{account_id: account.id})

      body = conn |> get(~p"/users/alice/outbox?page=1") |> json_response(200)

      assert body["orderedItems"] == [Serializer.status_uri(status, account)]
    end
  end
end
