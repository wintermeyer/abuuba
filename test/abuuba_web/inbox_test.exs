defmodule AbuubaWeb.InboxTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Ecto.Query, only: [from: 2]
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Keypair
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Availability
  alias Abuuba.Federation.Inbox
  alias Abuuba.Federation.Signature
  alias Abuuba.Federation.URIs
  alias Abuuba.Relationships
  alias Abuuba.Repo

  @actor "https://remote.example/users/alice"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    %{public_key: public, private_key: private} = Keypair.generate()

    account =
      remote_account_fixture(%{username: "alice", domain: "remote.example", uri: @actor})

    {:ok, _keypair} =
      Repo.insert(%Keypair{account_id: account.id, public_key: public, type: :rsa_2048})

    %{account: account, private: private}
  end

  defp deliver(conn, activity, private, opts \\ []) do
    body = Jason.encode!(activity)
    path = Keyword.get(opts, :path, "/inbox")

    {:ok, headers} =
      Signature.sign(
        method: :post,
        url: "#{URIs.base_url()}#{path}",
        body: body,
        key_id: Keyword.get(opts, :key_id, @actor <> "#main-key"),
        private_key: private
      )

    conn
    |> put_req_header("content-type", "application/activity+json")
    |> apply_signed_headers(headers)
    |> post(path, body)
  end

  defp create_activity(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "https://remote.example/activities/1",
        "type" => "Create",
        "actor" => @actor,
        "to" => [@public],
        "object" => %{
          "id" => "https://remote.example/statuses/1",
          "type" => "Note",
          "attributedTo" => @actor,
          "content" => "hello",
          "to" => [@public]
        }
      },
      overrides
    )
  end

  describe "delivery" do
    test "is accepted and answered immediately", %{conn: conn, private: private} do
      conn = deliver(conn, create_activity(), private)

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "queues the work rather than doing it inline", %{conn: conn, private: private} do
      # A sender is holding a socket open, and the work means requests of our
      # own to servers that may be slow.
      deliver(conn, create_activity(), private)

      assert [_job] = Repo.all(Oban.Job)
    end

    test "works on a per-actor inbox too", %{conn: conn, private: private} do
      account_fixture(%{username: "local"})

      conn = deliver(conn, create_activity(), private, path: "/users/local/inbox")

      assert conn.status == 202
    end

    test "brings a server we had given up on back to life", %{conn: conn, private: private} do
      # A server that is talking to us is running, whatever our own outbound
      # attempts concluded. Continuing to treat it as dead would be believing
      # our diagnosis over the evidence.
      for day <- 1..Availability.failure_days_before_unavailable() do
        Availability.record_failure("remote.example", Date.add(Date.utc_today(), -day))
      end

      assert Availability.unavailable?("remote.example")

      conn = deliver(conn, create_activity(), private)

      assert conn.status == 202
      refute Availability.unavailable?("remote.example")
    end

    test "a request we refuse does not count as the server being alive", %{conn: conn} do
      # Anybody can open a socket. Only a verified signature says which server
      # is on the other end of it.
      for day <- 1..Availability.failure_days_before_unavailable() do
        Availability.record_failure("remote.example", Date.add(Date.utc_today(), -day))
      end

      conn =
        conn
        |> put_req_header("content-type", "application/activity+json")
        |> post("/inbox", Jason.encode!(create_activity()))

      assert conn.status == 401
      assert Availability.unavailable?("remote.example")
    end
  end

  describe "requests we refuse" do
    test "one with no signature", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/activity+json")
        |> post("/inbox", Jason.encode!(create_activity()))

      assert conn.status == 401
    end

    test "one signed by a key we cannot find", %{conn: conn} do
      %{private_key: stranger} = Keypair.generate()

      conn =
        deliver(conn, create_activity(), stranger,
          key_id: "https://nowhere.example/users/nobody#main-key"
        )

      assert conn.status in [401, 503]
    end

    test "one whose body was changed after signing", %{conn: conn, private: private} do
      body = Jason.encode!(create_activity())

      {:ok, headers} =
        Signature.sign(
          method: :post,
          url: "#{URIs.base_url()}/inbox",
          body: body,
          key_id: @actor <> "#main-key",
          private_key: private
        )

      tampered = Jason.encode!(create_activity(%{"type" => "Delete"}))

      conn =
        conn
        |> apply_signed_headers(headers)
        |> put_req_header("content-type", "application/activity+json")
        |> post("/inbox", tampered)

      assert conn.status == 401
    end

    test "one whose actor is on a different host from the signer", %{conn: conn, private: private} do
      # The signature says who sent it; the activity says who did it. One actor
      # speaking for another on a different host is the forgery this catches.
      activity = create_activity(%{"actor" => "https://good.example/users/bob"})

      conn = deliver(conn, activity, private)

      assert conn.status == 403
    end

    test "one built with JSON-LD constructions we do not read", %{conn: conn, private: private} do
      # Plain map access would read this as an activity with no object at all.
      # Acting on the part we can see is worse than not acting, because the
      # sender chose which part that is.
      activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Create",
        "actor" => @actor,
        "@graph" => [%{"type" => "Delete", "object" => "https://remote.example/statuses/1"}]
      }

      conn = deliver(conn, activity, private)

      assert conn.status == 422
      assert Repo.all(Oban.Job) == []
    end

    test "one hiding the construction inside its object", %{conn: conn, private: private} do
      activity = create_activity(%{"object" => %{"type" => "Note", "@reverse" => %{}}})

      assert deliver(conn, activity, private).status == 422
    end

    test "one with no actor at all", %{conn: conn, private: private} do
      activity = create_activity() |> Map.delete("actor")

      assert deliver(conn, activity, private).status == 403
    end

    test "one that is not JSON", %{conn: conn, private: private} do
      # Refused before it reaches the controller, by the parser. Still a 400,
      # which is the answer that matters to the sender.
      body = "not json"

      {:ok, headers} =
        Signature.sign(
          method: :post,
          url: "#{URIs.base_url()}/inbox",
          body: body,
          key_id: @actor <> "#main-key",
          private_key: private
        )

      assert_error_sent 400, fn ->
        conn
        |> apply_signed_headers(headers)
        |> put_req_header("content-type", "application/activity+json")
        |> post("/inbox", body)
      end
    end
  end

  describe "relevance" do
    test "a public activity from nobody we follow is not worth work" do
      # A relay can forward every public post on the fediverse. Signature
      # checks pass, because the sender really is who they say.
      refute Inbox.relevant?(create_activity())
    end

    test "a public activity from somebody a local account follows is", %{account: account} do
      {:ok, _} = Relationships.follow(account_fixture(), account)

      assert Inbox.relevant?(create_activity())
    end

    test "a public activity addressing a local account is" do
      local = account_fixture(%{username: "local"})

      assert Inbox.relevant?(create_activity(%{"to" => [@public, Actor.id(local)]}))
    end

    test "a public reply to a local post is" do
      local = account_fixture(%{username: "local"})
      status = status_fixture(%{account_id: local.id, uri: "#{URIs.base_url()}/statuses/1"})

      activity =
        create_activity(%{
          "object" => %{
            "id" => "https://remote.example/statuses/2",
            "type" => "Note",
            "attributedTo" => @actor,
            "inReplyTo" => status.uri
          }
        })

      assert Inbox.relevant?(activity)
    end

    test "anything not public is relevant, whoever it is from" do
      # A direct message from a stranger is unsolicited by definition, and
      # refusing it would mean nobody here could ever be contacted first.
      assert Inbox.relevant?(create_activity(%{"to" => ["https://here.example/users/local"]}))
    end
  end

  describe "tombstones" do
    test "remember a delete so a redelivery costs nothing" do
      uri = "https://remote.example/statuses/gone"

      refute Inbox.tombstoned?(uri)

      Inbox.tombstone(uri)

      assert Inbox.tombstoned?(uri)
    end

    test "recording the same delete twice is not an error" do
      uri = "https://remote.example/statuses/gone"

      assert Inbox.tombstone(uri) == :ok
      assert Inbox.tombstone(uri) == :ok
    end

    test "expire, so the table does not grow forever" do
      uri = "https://remote.example/statuses/old"
      Inbox.tombstone(uri)

      Repo.update_all(from(t in "tombstones", where: t.uri == ^uri),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -7, :hour)]
      )

      refute Inbox.tombstoned?(uri)
      assert Inbox.sweep_tombstones() >= 1
    end
  end

  describe "activities that are no work" do
    test "a delete for something we never had" do
      # We cannot delete what we do not have, and fetching to find out would be
      # a request for an object the sender has just told us is gone.
      activity = %{"type" => "Delete", "object" => "https://remote.example/statuses/unknown"}

      assert Inbox.no_op?(activity)
    end

    test "a delete for something already tombstoned", %{account: account} do
      status = status_fixture(%{account_id: account.id, uri: "https://remote.example/statuses/1"})

      activity = %{"type" => "Delete", "object" => status.uri}

      refute Inbox.no_op?(activity), "the first delete is real work"

      Inbox.tombstone(status.uri)

      assert Inbox.no_op?(activity), "a redelivery of it is not"
    end

    test "a delete or update with no object at all" do
      assert Inbox.no_op?(%{"type" => "Delete"})
      assert Inbox.no_op?(%{"type" => "Update"})
    end

    test "an ordinary create is never a no-op" do
      refute Inbox.no_op?(create_activity())
    end
  end
end
