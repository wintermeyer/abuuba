defmodule AbuubaWeb.API.StreamingUpgradeTest do
  @moduledoc """
  What the streaming endpoint says to a request that is not a WebSocket
  upgrade.

  A client that upgrades properly never sees this. What does is everything
  else: a health checker, a crawler, a pasted URL, and — the one that matters —
  a client whose proxy stripped the `Upgrade` header, where a 500 turns
  somebody else's misconfiguration into what looks like a fault here.
  """

  use AbuubaWeb.ConnCase, async: true

  for path <- ["/api/v1/streaming", "/api/v2/streaming"] do
    test "a plain GET to #{path} is a 404 rather than an exception", %{conn: conn} do
      # Mastodon's streaming server handles upgrades on the `upgrade` event, so
      # an ordinary GET matches no route there and falls through to its
      # `httpNotFound`. This is that answer.
      conn = get(conn, unquote(path))

      assert json_response(conn, 404) == %{"error" => "Not found"}
    end
  end

  test "a request carrying Upgrade but no Connection is not one either", %{conn: conn} do
    # The case worth naming: a proxy that forwards `Upgrade` and drops
    # `Connection` is the likeliest way a real client lands here, and it used
    # to be told the server had crashed.
    conn =
      conn
      |> put_req_header("upgrade", "websocket")
      |> get("/api/v1/streaming")

    assert json_response(conn, 404) == %{"error" => "Not found"}
  end

  test "but a browser's `Connection: keep-alive, Upgrade` is", %{conn: conn} do
    # Header is a list, and browsers send both tokens in it. Reading it as an
    # exact match rather than as a list of tokens would refuse every real
    # WebSocket while every test above still passed.
    conn =
      conn
      |> put_req_header("connection", "keep-alive, Upgrade")
      |> put_req_header("upgrade", "websocket")

    # Reaching the adapter is the pass. It then raises, because Plug.Test
    # carries the host on the conn rather than as a header and WebSockAdapter
    # wants the header — which cannot happen through Bandit, where HTTP/1.1
    # makes Host mandatory. Against a running server this same request answers
    # 101; what is being asserted here is only that the guard did not turn it
    # away as "not a WebSocket request".
    assert_raise WebSockAdapter.UpgradeError, fn -> get(conn, "/api/v1/streaming") end
  end

  test "and the health check still answers", %{conn: conn} do
    # The positive control: if the streaming pipeline stopped serving anything
    # at all, the assertions above would still pass.
    conn = get(conn, "/api/v1/streaming/health")

    assert response(conn, 200) == "OK"
  end
end
