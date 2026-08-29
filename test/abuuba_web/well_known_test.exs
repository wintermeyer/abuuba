defmodule AbuubaWeb.WellKnownTest do
  use AbuubaWeb.ConnCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Federation.URIs

  describe "GET /.well-known/webfinger" do
    test "describes a local account", %{conn: conn} do
      account = account_fixture(%{username: "alice"})

      conn = get(conn, ~p"/.well-known/webfinger?resource=acct:alice@#{URIs.local_domain()}")

      body = json_response(conn, 200)

      assert body["subject"] == "acct:alice@#{URIs.local_domain()}"

      assert Enum.any?(body["links"], fn link ->
               link["rel"] == "self" and link["href"] == URIs.actor_uri(account)
             end)
    end

    test "is served as JRD, not as plain JSON", %{conn: conn} do
      account_fixture(%{username: "alice"})

      conn = get(conn, ~p"/.well-known/webfinger?resource=acct:alice@#{URIs.local_domain()}")

      assert conn |> get_resp_header("content-type") |> hd() =~ "application/jrd+json"
    end

    test "is cached hard, because a handle's actor URI does not move", %{conn: conn} do
      account_fixture(%{username: "alice"})

      conn = get(conn, ~p"/.well-known/webfinger?resource=acct:alice@#{URIs.local_domain()}")

      assert conn |> get_resp_header("cache-control") |> hd() =~ "max-age=259200"
    end

    test "answers 404 for somebody who is not here", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/webfinger?resource=acct:nobody@#{URIs.local_domain()}")

      assert json_response(conn, 404)
    end

    test "refuses to answer for another domain", %{conn: conn} do
      # Answering here would be claiming to speak for somebody else's server.
      account_fixture(%{username: "alice"})

      conn = get(conn, ~p"/.well-known/webfinger?resource=acct:alice@elsewhere.example")

      assert json_response(conn, 404)
    end

    test "answers 410 for a suspended account, so a peer can tombstone it", %{conn: conn} do
      account_fixture(%{username: "alice", suspended_at: DateTime.utc_now()})

      conn = get(conn, ~p"/.well-known/webfinger?resource=acct:alice@#{URIs.local_domain()}")

      assert json_response(conn, 410)
    end

    test "refuses a resource it cannot parse", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/webfinger?resource=nonsense")

      assert json_response(conn, 400)
    end

    test "refuses a request with no resource at all", %{conn: conn} do
      assert conn |> get(~p"/.well-known/webfinger") |> json_response(400)
    end

    test "accepts the handle without the acct: prefix", %{conn: conn} do
      account_fixture(%{username: "alice"})

      conn = get(conn, ~p"/.well-known/webfinger?resource=alice@#{URIs.local_domain()}")

      assert json_response(conn, 200)["subject"]
    end
  end

  describe "GET /.well-known/host-meta" do
    test "points at the webfinger endpoint", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/host-meta")

      body = response(conn, 200)

      assert body =~ ~s(rel="lrdd")
      assert body =~ "#{URIs.base_url()}/.well-known/webfinger?resource={uri}"
      assert conn |> get_resp_header("content-type") |> hd() =~ "application/xrd+xml"
    end
  end
end
