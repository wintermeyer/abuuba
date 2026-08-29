defmodule AbuubaWeb.ActivityPubTest do
  # Not async: several tests here reach the instance actor, which is a
  # singleton at a fixed id. Two concurrent transactions inserting the same
  # primary key block on each other, and with the self-referencing foreign key
  # on accounts that shows up as a deadlock rather than a wait.
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.InstanceActor
  alias Abuuba.Federation.URIs
  alias Abuuba.Relationships

  defp actor_json(conn), do: json_response(conn, 200)

  describe "GET /users/:username" do
    test "serves an actor document other servers can use", %{conn: conn} do
      account = account_fixture(%{username: "alice", display_name: "Alice", note: "hi"})
      {:ok, _keypair} = Accounts.create_keypair(account)

      body = conn |> get(~p"/users/alice") |> actor_json()

      assert body["id"] == "#{URIs.base_url()}/users/alice"
      assert body["type"] == "Person"
      assert body["preferredUsername"] == "alice"
      assert body["name"] == "Alice"
      assert body["summary"] == "hi"
      assert body["inbox"] == "#{URIs.base_url()}/users/alice/inbox"
      assert body["outbox"] == "#{URIs.base_url()}/users/alice/outbox"
      assert body["followers"] == "#{URIs.base_url()}/users/alice/followers"
      assert body["following"] == "#{URIs.base_url()}/users/alice/following"
      assert body["endpoints"]["sharedInbox"] == URIs.shared_inbox_url()
      assert body["published"]
    end

    test "carries the public key, which is what signatures are checked against", %{conn: conn} do
      account = account_fixture(%{username: "alice"})
      {:ok, keypair} = Accounts.create_keypair(account)

      body = conn |> get(~p"/users/alice") |> actor_json()

      assert body["publicKey"]["id"] == "#{URIs.base_url()}/users/alice#main-key"
      assert body["publicKey"]["owner"] == "#{URIs.base_url()}/users/alice"
      assert body["publicKey"]["publicKeyPem"] == keypair.public_key
    end

    test "is served as activity+json, which is how a peer recognises it", %{conn: conn} do
      account_fixture(%{username: "alice"})

      conn = get(conn, ~p"/users/alice")

      assert conn |> get_resp_header("content-type") |> hd() =~ "application/activity+json"
    end

    test "renders profile fields as PropertyValue, which is what clients read", %{conn: conn} do
      account_fixture(%{
        username: "alice",
        fields: [%{name: "Web", value: "https://alice.example"}]
      })

      body = conn |> get(~p"/users/alice") |> actor_json()

      assert [%{"type" => "PropertyValue", "name" => "Web", "value" => "https://alice.example"}] =
               body["attachment"]
    end

    test "says when followers need approving", %{conn: conn} do
      account_fixture(%{username: "alice", locked: true})

      assert conn |> get(~p"/users/alice") |> actor_json() |> Map.get("manuallyApprovesFollowers")
    end

    test "omits an absent movedTo rather than sending null", %{conn: conn} do
      # Some implementations read "movedTo": null as a move to nowhere.
      account_fixture(%{username: "alice"})

      body = conn |> get(~p"/users/alice") |> actor_json()

      refute Map.has_key?(body, "movedTo")
      refute Map.has_key?(body, "alsoKnownAs")
    end

    test "points at where the account moved to", %{conn: conn} do
      target = account_fixture(%{username: "bob"})

      account_fixture(%{
        username: "alice",
        moved_to_account_id: target.id,
        also_known_as: ["https://old.example/users/alice"]
      })

      body = conn |> get(~p"/users/alice") |> actor_json()

      assert body["movedTo"] == "#{URIs.base_url()}/users/bob"
      assert body["alsoKnownAs"] == ["https://old.example/users/alice"]
    end

    test "answers 410 for a suspended account", %{conn: conn} do
      account_fixture(%{username: "alice", suspended_at: DateTime.utc_now()})

      assert conn |> get(~p"/users/alice") |> json_response(410)
    end

    test "answers 404 for somebody who is not here", %{conn: conn} do
      assert conn |> get(~p"/users/nobody") |> json_response(404)
    end

    test "does not serve a remote account as if it were ours", %{conn: conn} do
      remote_account_fixture(%{username: "alice", domain: "remote.example"})

      assert conn |> get(~p"/users/alice") |> json_response(404)
    end
  end

  describe "both URI schemes" do
    test "an account on the numeric scheme is served there", %{conn: conn} do
      account = account_fixture(%{username: "alice", id_scheme: :numeric})

      body = conn |> get(~p"/ap/users/#{account.id}") |> actor_json()

      assert body["id"] == "#{URIs.base_url()}/ap/users/#{account.id}"

      assert body["inbox"] == "#{URIs.base_url()}/ap/users/#{account.id}/inbox",
             "every URI in the document has to follow the id, or a peer fetches the wrong one"
    end

    test "a username-scheme account keeps its username id even when fetched by number", %{
      conn: conn
    } do
      # Other servers stored the username URI, so the numeric path has to keep
      # leading to it. It used to serve the document here with the canonical
      # id inside, which strict peers refuse -- a document whose id is not the
      # URL it came from. A permanent redirect keeps the old address working
      # and ends the chain where the id says it lives.
      account = account_fixture(%{username: "alice"})

      conn = get(conn, ~p"/ap/users/#{account.id}")

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["#{URIs.base_url()}/users/alice"]
    end

    test "refuses a numeric path that is not a number", %{conn: conn} do
      assert conn |> get(~p"/ap/users/not-a-number") |> json_response(404)
    end
  end

  describe "the instance actor" do
    test "exists on first ask, without a setup step", %{conn: conn} do
      body = conn |> get(~p"/actor") |> actor_json()

      assert body["type"] == "Application"
      assert body["id"] == "#{URIs.base_url()}/actor"
      assert body["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
    end

    test "sits at the reserved id, so its URL survives a rebuild", %{conn: _conn} do
      actor = InstanceActor.fetch!()

      assert actor.id == Accounts.instance_actor_id()
      assert actor.id < 0
    end

    test "is created even where the host carries a port, as it does in development" do
      # The instance actor is named after the host, and a colon is not a legal
      # username. Without stripping the port, `mix phx.server` cannot sign a
      # single outbound request.
      original = Application.get_env(:abuuba, :local_domain)
      Application.put_env(:abuuba, :local_domain, "localhost:4000")
      on_exit(fn -> Application.put_env(:abuuba, :local_domain, original) end)

      assert InstanceActor.fetch!().username == "localhost"
    end

    test "is the same actor on a second ask", %{conn: conn} do
      first = InstanceActor.fetch!()
      _second_response = get(conn, ~p"/actor")

      assert InstanceActor.fetch!().id == first.id
    end

    test "describes nothing about a person, because it is not one", %{conn: conn} do
      body = conn |> get(~p"/actor") |> actor_json()

      refute body["discoverable"]
      refute body["indexable"]
      refute Map.has_key?(body, "outbox")
      refute Map.has_key?(body, "followers")
    end
  end

  describe "collections" do
    setup do
      account = account_fixture(%{username: "alice"})
      %{account: account}
    end

    test "advertise a size and a first page rather than the contents", %{
      conn: conn,
      account: account
    } do
      for _ <- 1..3, do: Relationships.follow(account_fixture(), account)

      body = conn |> get(~p"/users/alice/followers") |> actor_json()

      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] == 3
      assert body["first"] =~ "?page=1"
      refute Map.has_key?(body, "orderedItems")
    end

    test "hand out actor URIs on a page", %{conn: conn, account: account} do
      follower = account_fixture(%{username: "bob"})
      {:ok, _} = Relationships.follow(follower, account)

      body = conn |> get(~p"/users/alice/followers?page=1") |> actor_json()

      assert body["type"] == "OrderedCollectionPage"
      assert body["orderedItems"] == [Actor.id(follower)]
      assert body["partOf"] =~ "/users/alice/followers"
    end

    test "offer a next page only while there is one", %{conn: conn, account: account} do
      for _ <- 1..25, do: Relationships.follow(account_fixture(), account)

      first = conn |> get(~p"/users/alice/followers?page=1") |> actor_json()
      second = build_conn() |> get(~p"/users/alice/followers?page=2") |> actor_json()

      assert length(first["orderedItems"]) == 20
      assert first["next"] =~ "page=2"

      assert length(second["orderedItems"]) == 5
      refute Map.has_key?(second, "next")
    end

    test "following lists the other direction", %{conn: conn, account: account} do
      target = account_fixture(%{username: "bob"})
      {:ok, _} = Relationships.follow(account, target)

      body = conn |> get(~p"/users/alice/following?page=1") |> actor_json()

      assert body["orderedItems"] == [Actor.id(target)]
    end

    test "look empty rather than forbidden when hidden", %{conn: conn, account: account} do
      # A 403 would tell a stranger there is something here worth hiding.
      {:ok, _} = Relationships.follow(account_fixture(), account)
      Abuuba.Repo.update!(Ecto.Changeset.change(account, hide_collections: true))

      body = conn |> get(~p"/users/alice/followers") |> actor_json()

      assert body["totalItems"] == 0
      refute Map.has_key?(body, "first")
    end

    test "survive a peer asking for a nonsense page", %{conn: conn} do
      body = conn |> get(~p"/users/alice/followers?page=banana") |> actor_json()

      assert body["type"] == "OrderedCollectionPage"
    end
  end

  describe "the outbox" do
    test "carries only what is already public", %{conn: conn} do
      account = account_fixture(%{username: "alice"})

      public = status_fixture(%{account_id: account.id, uri: "https://here.example/s/1"})

      status_fixture(%{
        account_id: account.id,
        visibility: :unlisted,
        uri: "https://here.example/s/2"
      })

      status_fixture(%{
        account_id: account.id,
        visibility: :private,
        uri: "https://here.example/s/3"
      })

      status_fixture(%{
        account_id: account.id,
        visibility: :direct,
        uri: "https://here.example/s/4"
      })

      body = conn |> get(~p"/users/alice/outbox?page=1") |> actor_json()

      assert body["orderedItems"] == [public.uri]
    end

    test "leaves out deleted posts", %{conn: conn} do
      account = account_fixture(%{username: "alice"})
      status = status_fixture(%{account_id: account.id, uri: "https://here.example/s/1"})
      Abuuba.Statuses.delete_status(status)

      body = conn |> get(~p"/users/alice/outbox") |> actor_json()

      assert body["totalItems"] == 0
    end
  end
end
