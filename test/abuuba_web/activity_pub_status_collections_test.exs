defmodule AbuubaWeb.ActivityPubStatusCollectionsTest do
  @moduledoc """
  The three collections that hang off a post.

  `replies` is the one that does work: a server that received a reply without
  its parent, or a parent without its replies, walks it to fill the thread in.
  `likes` and `shares` publish a number and nothing else, which is deliberate.
  Naming who favourited a post would hand a scraper a list of people who read
  it, and the reference implementation publishes the count alone.
  """

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

  # Two `replies` objects fetched unauthenticated from mastodon.social, one from
  # a post whose author replied to themselves and one from a post nobody had
  # replied to. They are recorded so the next reader can see where this
  # collection's shape came from: the published protocol documentation and the
  # network, never the AGPL implementation (CONTRIBUTING.md, "The clean-room
  # rule"). The file's own `source` block says how to fetch them again.
  @wire "test/support/data/mastodon_replies_collection.json"
        |> File.read!()
        |> Jason.decode!()

  defp document(conn), do: json_response(conn, 200)

  defp wire(sample), do: @wire["samples"][sample]["replies"]

  defp query_keys(url) do
    url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.keys() |> Enum.sort()
  end

  defp next_query_keys(status) do
    status |> Serializer.note() |> get_in(["replies", "first", "next"]) |> query_keys()
  end

  defp reply_to(parent, account, attrs \\ %{}) do
    attrs
    |> Map.merge(%{account_id: account.id, in_reply_to_id: parent.id})
    |> status_fixture()
  end

  describe "likes and shares" do
    setup do
      account = account_fixture(%{username: "alice"})
      status = status_fixture(%{account_id: account.id})
      %{account: account, status: status}
    end

    test "publish how many, and never who", %{conn: conn, account: account, status: status} do
      {:ok, _favourite} = Statuses.favourite(account_fixture(), status)
      {:ok, _favourite} = Statuses.favourite(account_fixture(), status)

      body = conn |> get(~p"/users/alice/statuses/#{status.id}/likes") |> document()

      assert body["id"] == Serializer.status_uri(status, account) <> "/likes"
      assert body["type"] == "Collection"
      assert body["totalItems"] == 2
      # Naming them would publish who read the post, which nobody agreed to.
      refute Map.has_key?(body, "items")
      refute Map.has_key?(body, "orderedItems")
    end

    test "count the boosts the same way", %{conn: conn, account: account, status: status} do
      {:ok, _boost} = Statuses.boost(account_fixture(), status)

      body = conn |> get(~p"/users/alice/statuses/#{status.id}/shares") |> document()

      assert body["id"] == Serializer.status_uri(status, account) <> "/shares"
      assert body["type"] == "Collection"
      assert body["totalItems"] == 1
    end

    test "are zero rather than absent on a post nobody touched", %{conn: conn, status: status} do
      assert conn
             |> get(~p"/users/alice/statuses/#{status.id}/likes")
             |> document()
             |> Map.fetch!("totalItems") == 0
    end
  end

  describe "replies" do
    setup do
      author = account_fixture(%{username: "alice"})
      parent = status_fixture(%{account_id: author.id, text: "the parent"})
      %{author: author, parent: parent}
    end

    test "advertise a first page rather than the whole thread", %{
      conn: conn,
      author: author,
      parent: parent
    } do
      body = conn |> get(~p"/users/alice/statuses/#{parent.id}/replies") |> document()

      collection_id = Serializer.status_uri(parent, author) <> "/replies"

      assert body["id"] == collection_id
      assert body["type"] == "Collection"
      assert body["first"]["type"] == "CollectionPage"
      assert body["first"]["partOf"] == collection_id
    end

    test "list the author's own replies first, which is how a thread reads", %{
      conn: conn,
      author: author,
      parent: parent
    } do
      own = reply_to(parent, author, %{text: "and then"})
      stranger = reply_to(parent, account_fixture(), %{text: "a stranger"})

      items = conn |> get(~p"/users/alice/statuses/#{parent.id}/replies") |> document()
      items = items["first"]["items"]

      assert items == [Serializer.status_uri(own, author)]
      refute Serializer.status_uri(stranger, nil) in items
    end

    test "declare their vocabulary when fetched on their own", %{conn: conn, parent: parent} do
      # A page fetched directly is a document in its own right. Without
      # `@context` a strict peer reads `items` as an undefined term and drops
      # the whole page.
      body = conn |> get(~p"/users/alice/statuses/#{parent.id}/replies?page=true") |> document()

      assert body["@context"]
    end

    test "survive a peer sending a min_id no column could hold", %{conn: conn, parent: parent} do
      assert conn
             |> get(
               ~p"/users/alice/statuses/#{parent.id}/replies?page=true&min_id=99999999999999999999"
             )
             |> document()
             |> Map.fetch!("type") == "CollectionPage"
    end

    test "hand out everybody else's on the only_other_accounts page", %{
      conn: conn,
      author: author,
      parent: parent
    } do
      other = account_fixture()
      _own = reply_to(parent, author)
      theirs = reply_to(parent, other)

      body =
        conn
        |> get(~p"/users/alice/statuses/#{parent.id}/replies?page=true&only_other_accounts=true")
        |> document()

      assert body["type"] == "CollectionPage"
      assert body["items"] == [Serializer.status_uri(theirs, other)]
    end

    test "point the next page at everybody else once the author is exhausted", %{
      conn: conn,
      author: author,
      parent: parent
    } do
      _own = reply_to(parent, author)

      body =
        conn |> get(~p"/users/alice/statuses/#{parent.id}/replies?page=true") |> document()

      # A peer that stopped here would see only the author talking to themselves.
      assert body["next"] =~ "only_other_accounts=true"
    end

    test "leave out what was never public", %{conn: conn, author: author, parent: parent} do
      public = reply_to(parent, author)
      unlisted = reply_to(parent, author, %{visibility: :unlisted})
      _private = reply_to(parent, author, %{visibility: :private})
      _direct = reply_to(parent, author, %{visibility: :direct})

      items =
        conn
        |> get(~p"/users/alice/statuses/#{parent.id}/replies?page=true")
        |> document()
        |> Map.fetch!("items")

      assert items == [
               Serializer.status_uri(public, author),
               Serializer.status_uri(unlisted, author)
             ]
    end

    test "name a reply that came from elsewhere by the id its own server gave it", %{
      conn: conn,
      parent: parent
    } do
      remote =
        remote_account_fixture(%{
          username: "bob",
          domain: "peer.example",
          uri: "https://peer.example/users/bob"
        })

      reply_to(parent, remote, %{local: false, uri: "https://peer.example/s/9"})

      body =
        conn
        |> get(~p"/users/alice/statuses/#{parent.id}/replies?page=true&only_other_accounts=true")
        |> document()

      assert body["items"] == ["https://peer.example/s/9"]
    end

    test "walk forward by min_id rather than by page number", %{
      conn: conn,
      author: author,
      parent: parent
    } do
      first = reply_to(parent, author)
      second = reply_to(parent, author)

      body =
        conn
        |> get(~p"/users/alice/statuses/#{parent.id}/replies?page=true&min_id=#{first.id}")
        |> document()

      assert body["items"] == [Serializer.status_uri(second, author)]
    end
  end

  describe "the shape a peer already knows" do
    setup do
      author = account_fixture(%{username: "alice"})
      %{author: author, parent: status_fixture(%{account_id: author.id})}
    end

    test "names every key a peer reads off a Mastodon post", %{author: author, parent: parent} do
      reply_to(parent, author)

      ours = Map.fetch!(Serializer.note(parent), "replies")
      theirs = wire("author_replied")

      # More is fine, less is not: ours also gives the page an id, which the
      # reference implementation leaves anonymous.
      assert Map.keys(theirs) -- Map.keys(ours) == []
      assert Map.keys(theirs["first"]) -- Map.keys(ours["first"]) == []
      assert ours["type"] == theirs["type"]
      assert ours["first"]["type"] == theirs["first"]["type"]
      assert ours["first"]["partOf"] == ours["id"]
    end

    test "walks on by the parameters a peer expects", %{author: author, parent: parent} do
      unanswered = status_fixture(%{account_id: author.id})
      reply_to(parent, author)

      assert next_query_keys(parent) == query_keys(wire("author_replied")["first"]["next"])
      assert next_query_keys(unanswered) == query_keys(wire("no_self_replies")["first"]["next"])
    end
  end

  describe "a Note carries its own replies" do
    test "so a peer that fetched the post has the thread's start", %{conn: conn} do
      author = account_fixture(%{username: "alice"})
      parent = status_fixture(%{account_id: author.id})
      reply = reply_to(parent, author)

      body = conn |> get(~p"/users/alice/statuses/#{parent.id}") |> document()

      collection_id = Serializer.status_uri(parent, author) <> "/replies"

      assert body["replies"]["id"] == collection_id
      assert body["replies"]["first"]["items"] == [Serializer.status_uri(reply, author)]
      assert body["likes"]["type"] == "Collection"
      assert body["shares"]["type"] == "Collection"
    end

    test "and a post from elsewhere keeps whatever its own server said", %{conn: _conn} do
      remote =
        remote_account_fixture(%{
          username: "bob",
          domain: "peer.example",
          uri: "https://peer.example/users/bob"
        })

      status =
        status_fixture(%{account_id: remote.id, local: false, uri: "https://peer.example/s/1"})

      # Nothing here speaks for another server's post, so no collection of ours
      # is attached to it.
      document = Serializer.note(status)

      refute Map.has_key?(document, "replies")
      refute Map.has_key?(document, "likes")
      refute Map.has_key?(document, "shares")
    end
  end

  describe "who may read a collection" do
    setup do
      author = account_fixture(%{username: "alice"})
      %{public_key: public, private_key: private} = Keypair.generate()

      peer =
        remote_account_fixture(%{
          username: "stranger",
          domain: "peer.example",
          uri: "https://peer.example/users/stranger"
        })

      {:ok, _keypair} =
        Repo.insert(%Keypair{account_id: peer.id, public_key: public, type: :rsa_2048})

      status = status_fixture(%{account_id: author.id, visibility: :private})

      %{author: author, peer: peer, private: private, status: status}
    end

    defp signed_get(conn, path, private_key) do
      {:ok, headers} =
        Signature.sign(
          method: :get,
          url: URIs.base_url() <> path,
          key_id: "https://peer.example/users/stranger#main-key",
          private_key: private_key
        )

      conn |> apply_signed_headers(headers) |> get(path)
    end

    test "a follower may, which is what makes the refusals below mean anything", %{
      conn: conn,
      author: author,
      peer: peer,
      private: private,
      status: status
    } do
      {:ok, _follow} = Relationships.follow(peer, author)

      body = signed_get(conn, "/users/alice/statuses/#{status.id}/replies", private) |> document()

      assert body["type"] == "Collection"
    end

    test "a stranger may not read the replies of a post they cannot read", %{
      conn: conn,
      private: private,
      status: status
    } do
      assert conn
             |> signed_get("/users/alice/statuses/#{status.id}/replies", private)
             |> json_response(404)
    end

    test "nor its likes", %{conn: conn, status: status} do
      assert conn |> get(~p"/users/alice/statuses/#{status.id}/likes") |> json_response(404)
    end

    test "nor its shares", %{conn: conn, status: status} do
      assert conn |> get(~p"/users/alice/statuses/#{status.id}/shares") |> json_response(404)
    end
  end
end
