defmodule AbuubaWeb.HumanRedirectTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  setup do
    account = account_fixture(%{username: "alice"})
    status = status_fixture(%{account_id: account.id, text: "something public"})

    %{account: account, status: status}
  end

  describe "a browser opening a federated address" do
    test "is sent to the profile", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "text/html,application/xhtml+xml,*/*;q=0.8")
        |> get("/users/alice")

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/@alice"]
    end

    test "is sent to the post", %{conn: conn, status: status} do
      conn =
        conn
        |> put_req_header("accept", "text/html,application/xhtml+xml,*/*;q=0.8")
        |> get("/users/alice/statuses/#{status.id}")

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/@alice/#{status.id}"]
    end

    test "and the page it lands on is really there", %{conn: conn, status: status} do
      # A redirect to a 404 would be a worse answer than the 406 it replaces.
      assert conn |> get("/@alice") |> html_response(200) =~ "alice"
      assert conn |> get("/@alice/#{status.id}") |> html_response(200) =~ "something public"
    end

    test "says the answer depends on the Accept header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "text/html")
        |> get("/users/alice")

      # A cache that stored this and served it to another server would break
      # federation for everybody behind that cache.
      assert get_resp_header(conn, "vary") == ["Accept"]
    end
  end

  describe "a server asking for the same address" do
    test "gets the actor", %{conn: conn} do
      body =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/alice")
        |> json_response(200)

      assert body["preferredUsername"] == "alice"
    end

    test "gets the post", %{conn: conn, status: status} do
      body =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/users/alice/statuses/#{status.id}")
        |> json_response(200)

      assert body["id"]
    end

    test "is left alone when it sends anything alongside */*", %{conn: conn} do
      # A peer that lists `*/*` next to activity+json must not be sent to a
      # page, whatever else its header says.
      assert conn
             |> put_req_header("accept", "application/activity+json, text/html;q=0.1, */*")
             |> get("/users/alice")
             |> json_response(200)
    end

    test "is left alone when it sends no Accept header at all", %{conn: conn} do
      assert conn |> get("/users/alice") |> json_response(200)
    end
  end

  describe "what is deliberately not redirected" do
    test "a collection, which has no page", %{conn: conn} do
      # A browser opening the outbox is asking for something with no page, and
      # a redirect to the profile would answer a question nobody asked. It
      # keeps refusing, which is the honest answer for an address that has no
      # human version.
      assert_raise Phoenix.NotAcceptableError, fn ->
        conn |> put_req_header("accept", "text/html") |> get("/users/alice/outbox")
      end
    end

    test "an ordinary API call", %{conn: conn} do
      assert_raise Phoenix.NotAcceptableError, fn ->
        conn |> put_req_header("accept", "text/html") |> get("/api/v1/instance")
      end
    end
  end

  describe "a name nobody has" do
    test "still redirects, and the page says so", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "text/html")
        |> get("/users/nobody")

      # Checked at the page rather than here: a plug that looked the account up
      # would query on every API request to decide about two paths.
      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/@nobody"]
    end
  end
end
