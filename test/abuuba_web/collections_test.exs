defmodule AbuubaWeb.CollectionsTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Collections
  alias Abuuba.Collections.Collection
  alias Abuuba.Notifications
  alias Abuuba.OAuth

  setup %{conn: conn} do
    account = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> raw),
      anon: build_conn(),
      account: account
    }
  end

  defp made(conn, attrs \\ %{}) do
    json_response(
      post(conn, "/api/v1/collections", Map.merge(%{"name" => "Gardeners"}, attrs)),
      200
    )
  end

  describe "publishing a list" do
    test "makes one, changes it, reads it back and deletes it", %{conn: conn, anon: anon} do
      created = made(conn, %{"description" => "People who write about plants"})

      assert created["name"] == "Gardeners"
      assert created["description"] == "People who write about plants"
      assert created["item_count"] == 0
      assert created["items"] == []
      assert created["local"] == true
      # Two addresses: one for other servers, one for a person.
      assert created["uri"] =~ "/ap/collections/"
      assert created["url"] =~ "/collections/"

      updated =
        json_response(
          put(conn, "/api/v1/collections/#{created["id"]}", %{"name" => "Plant people"}),
          200
        )

      assert updated["name"] == "Plant people"

      # Reading one needs no token: the point is handing it to somebody who has
      # not signed up yet.
      assert json_response(get(anon, "/api/v1/collections/#{created["id"]}"), 200)["name"] ==
               "Plant people"

      assert json_response(delete(conn, "/api/v1/collections/#{created["id"]}"), 200) == %{}
      assert json_response(get(anon, "/api/v1/collections/#{created["id"]}"), 404)
    end

    test "refuses one with no name, and one too long", %{conn: conn} do
      assert json_response(post(conn, "/api/v1/collections", %{"name" => ""}), 422)

      assert json_response(
               post(conn, "/api/v1/collections", %{"name" => String.duplicate("x", 60)}),
               422
             )
    end

    test "stops at the number one account may publish", %{conn: conn} do
      for n <- 1..Collection.per_account_max() do
        assert made(conn, %{"name" => "List #{n}"})
      end

      assert json_response(post(conn, "/api/v1/collections", %{"name" => "One too many"}), 422)
    end

    test "somebody else's is not editable or deletable", %{conn: conn} do
      {:ok, theirs} = Collections.create(account_fixture(), %{"name" => "Theirs"})

      assert json_response(
               put(conn, "/api/v1/collections/#{theirs.id}", %{"name" => "Mine"}),
               404
             )

      assert json_response(delete(conn, "/api/v1/collections/#{theirs.id}"), 404)
      assert Collections.get(theirs.id).name == "Theirs"
    end

    test "carries the hashtag it is about, by name", %{conn: conn} do
      created = made(conn, %{"tag" => "#Gardening"})

      # The client picks a word; the tag row is this server's business.
      assert created["tag"] == %{"name" => "gardening"}
    end
  end

  describe "who is on it" do
    setup %{conn: conn} do
      %{collection: made(conn)}
    end

    test "adds somebody, counts them, and takes them off", %{conn: conn, collection: collection} do
      target = account_fixture()

      item =
        json_response(
          post(conn, "/api/v1/collections/#{collection["id"]}/items", %{
            "account_id" => to_string(target.id)
          }),
          200
        )

      assert item["state"] == "accepted"
      assert item["account_id"] == to_string(target.id)

      shown = json_response(get(conn, "/api/v1/collections/#{collection["id"]}"), 200)
      assert shown["item_count"] == 1
      assert [%{"account_id" => _}] = shown["items"]

      assert json_response(
               delete(conn, "/api/v1/collections/#{collection["id"]}/items/#{item["id"]}"),
               200
             ) == %{}

      assert json_response(get(conn, "/api/v1/collections/#{collection["id"]}"), 200)[
               "item_count"
             ] == 0
    end

    test "tells the person they were put on it", %{
      conn: conn,
      collection: collection,
      account: account
    } do
      # Somebody on a public list has a decision to make about it, and cannot
      # make it without knowing.
      target = account_fixture()

      post(conn, "/api/v1/collections/#{collection["id"]}/items", %{
        "account_id" => to_string(target.id)
      })

      assert [%{type: "collection_add", from_account_id: from}] = Notifications.list(target)
      assert from == account.id
    end

    test "will not add the same person twice", %{conn: conn, collection: collection} do
      target = account_fixture()
      params = %{"account_id" => to_string(target.id)}

      assert json_response(
               post(conn, "/api/v1/collections/#{collection["id"]}/items", params),
               200
             )

      assert json_response(
               post(conn, "/api/v1/collections/#{collection["id"]}/items", params),
               422
             )
    end

    test "stops at the number of accounts a list may hold", %{conn: conn, collection: collection} do
      for _ <- 1..Collection.items_max() do
        target = account_fixture()

        assert json_response(
                 post(conn, "/api/v1/collections/#{collection["id"]}/items", %{
                   "account_id" => to_string(target.id)
                 }),
                 200
               )
      end

      one_more = account_fixture()

      body =
        json_response(
          post(conn, "/api/v1/collections/#{collection["id"]}/items", %{
            "account_id" => to_string(one_more.id)
          }),
          422
        )

      assert body["error"] =~ "full"
    end

    test "somebody else cannot add to it", %{collection: collection} do
      %{conn: stranger} = signed_in()

      assert json_response(
               post(stranger, "/api/v1/collections/#{collection["id"]}/items", %{
                 "account_id" => to_string(account_fixture().id)
               }),
               404
             )
    end
  end

  describe "taking yourself off one" do
    test "is yours to do, and it is permanent", %{conn: conn} do
      collection = made(conn)
      %{conn: theirs, account: target} = signed_in()

      item =
        json_response(
          post(conn, "/api/v1/collections/#{collection["id"]}/items", %{
            "account_id" => to_string(target.id)
          }),
          200
        )

      assert json_response(
               post(theirs, "/api/v1/collections/#{collection["id"]}/items/#{item["id"]}/revoke"),
               200
             ) == %{}

      shown = json_response(get(conn, "/api/v1/collections/#{collection["id"]}"), 200)
      assert shown["item_count"] == 0
      assert shown["items"] == []

      # And the owner cannot simply put them back. That only works because the
      # revoked row survives.
      body =
        json_response(
          post(conn, "/api/v1/collections/#{collection["id"]}/items", %{
            "account_id" => to_string(target.id)
          }),
          422
        )

      assert body["error"] =~ "taken themselves off"
    end

    test "is not something a third party may do on somebody's behalf", %{conn: conn} do
      collection = made(conn)
      target = account_fixture()
      %{conn: stranger} = signed_in()

      item =
        json_response(
          post(conn, "/api/v1/collections/#{collection["id"]}/items", %{
            "account_id" => to_string(target.id)
          }),
          200
        )

      assert json_response(
               post(
                 stranger,
                 "/api/v1/collections/#{collection["id"]}/items/#{item["id"]}/revoke"
               ),
               403
             )

      assert json_response(get(conn, "/api/v1/collections/#{collection["id"]}"), 200)[
               "item_count"
             ] == 1
    end
  end

  describe "the account listings" do
    test "what somebody publishes, and what they are on", %{
      conn: conn,
      account: account,
      anon: anon
    } do
      collection = made(conn)
      target = account_fixture()

      post(conn, "/api/v1/collections/#{collection["id"]}/items", %{
        "account_id" => to_string(target.id)
      })

      assert [%{"id" => id}] =
               json_response(get(anon, "/api/v1/accounts/#{account.id}/collections"), 200)

      assert id == collection["id"]

      assert [%{"id" => same}] =
               json_response(get(anon, "/api/v1/accounts/#{target.id}/in_collections"), 200)

      assert same == collection["id"]
    end

    test "a list its owner hid is not a fact about the people on it", %{conn: conn, anon: anon} do
      collection = made(conn, %{"discoverable" => "false"})
      target = account_fixture()

      post(conn, "/api/v1/collections/#{collection["id"]}/items", %{
        "account_id" => to_string(target.id)
      })

      assert json_response(get(anon, "/api/v1/accounts/#{target.id}/in_collections"), 200) == []
    end
  end

  describe "the older path" do
    test "answers the same as v1", %{conn: conn} do
      # A client written before collections settled on v1 gets a list rather
      # than a 404.
      created =
        json_response(post(conn, "/api/v1_alpha/collections", %{"name" => "Alpha"}), 200)

      assert created["name"] == "Alpha"
      assert json_response(get(build_conn(), "/api/v1_alpha/collections/#{created["id"]}"), 200)
    end
  end

  describe "under a post" do
    test "names the lists about one of its hashtags", %{conn: conn, account: account} do
      collection = made(conn, %{"tag" => "gardening"})
      status = status_fixture(%{account_id: account.id, text: "beetroot again #gardening"})

      body = json_response(get(conn, "/api/v1/statuses/#{status.id}"), 200)

      assert [%{"id" => id}] = body["tagged_collections"]
      assert id == collection["id"]
    end

    test "says nothing for a post with no hashtags", %{conn: conn, account: account} do
      made(conn, %{"tag" => "gardening"})
      status = status_fixture(%{account_id: account.id, text: "beetroot again"})

      assert json_response(get(conn, "/api/v1/statuses/#{status.id}"), 200)["tagged_collections"] ==
               []
    end

    test "leaves out a list its owner hid", %{conn: conn, account: account} do
      made(conn, %{"tag" => "gardening", "discoverable" => "false"})
      status = status_fixture(%{account_id: account.id, text: "beetroot #gardening"})

      assert json_response(get(conn, "/api/v1/statuses/#{status.id}"), 200)["tagged_collections"] ==
               []
    end
  end

  describe "the page and what a peer reads" do
    test "renders on the server for somebody with no session", %{conn: conn, anon: anon} do
      collection = made(conn, %{"description" => "People who write about plants"})
      target = account_fixture(%{username: "bob", display_name: "Bob"})

      post(conn, "/api/v1/collections/#{collection["id"]}/items", %{
        "account_id" => to_string(target.id)
      })

      html = anon |> get("/collections/#{collection["id"]}") |> html_response(200)

      assert html =~ "Gardeners"
      assert html =~ "People who write about plants"
      assert html =~ "Bob"
      # The tags a chat window reads when the link is pasted into it.
      assert html =~ ~s(property="og:title")
    end

    test "a suspended account stops being recommended, on the page and to peers", %{conn: conn} do
      collection = made(conn)
      target = account_fixture(%{username: "gone"})

      post(conn, "/api/v1/collections/#{collection["id"]}/items", %{
        "account_id" => to_string(target.id)
      })

      {:ok, _} = Accounts.update_moderation(target, %{suspended_at: DateTime.utc_now()})

      html = build_conn() |> get("/collections/#{collection["id"]}") |> html_response(200)
      refute html =~ "gone"

      document =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/ap/collections/#{collection["id"]}")
        |> json_response(200)

      assert document["orderedItems"] == []
    end

    test "a peer reads actor ids rather than twenty-five profiles", %{conn: conn} do
      collection = made(conn)
      target = account_fixture(%{username: "bob"})

      post(conn, "/api/v1/collections/#{collection["id"]}/items", %{
        "account_id" => to_string(target.id)
      })

      document =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/ap/collections/#{collection["id"]}")
        |> json_response(200)

      assert document["type"] == "OrderedCollection"
      assert document["name"] == "Gardeners"
      assert document["totalItems"] == 1
      assert [uri] = document["orderedItems"]
      assert is_binary(uri)
      assert uri =~ "/users/bob"
    end

    test "an address nobody has is a plain miss", %{anon: anon} do
      assert_error_sent 404, fn -> get(anon, "/collections/999999") end
    end
  end

  defp signed_in do
    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "t2", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    %{conn: put_req_header(build_conn(), "authorization", "Bearer " <> raw), account: account}
  end
end
