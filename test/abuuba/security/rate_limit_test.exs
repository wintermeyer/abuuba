defmodule Abuuba.Security.RateLimitTest do
  use AbuubaWeb.ConnCase, async: false

  alias AbuubaWeb.ClientIP

  # A rate limit is only a rate limit if the thing it counts by cannot be
  # chosen by the person being limited.

  describe "what a limit counts by" do
    test "the address the connection came from, not a header" do
      # `X-Forwarded-For` is written by whoever sent the request. A limiter
      # that keyed on it would hand every attacker an unlimited number of
      # buckets, one per made-up address.
      conn =
        build_conn()
        |> Map.put(:remote_ip, {203, 0, 113, 5})
        |> put_req_header("x-forwarded-for", "10.0.0.1")
        |> put_req_header("x-real-ip", "10.0.0.2")
        |> put_req_header("forwarded", "for=10.0.0.3")

      assert ClientIP.of(conn) == "203.0.113.5"
    end

    test "and it is the same string for the same address every time" do
      # A key that changed between requests would be a limit of one request per
      # request.
      conn = Map.put(build_conn(), :remote_ip, {203, 0, 113, 5})

      assert ClientIP.of(conn) == ClientIP.of(conn)
    end
  end

  describe "signing in" do
    test "is limited, and the limit is enforced" do
      # Password guessing is the attack this exists to slow down, so the test
      # is that the door actually shuts.
      responses =
        for _attempt <- 1..30 do
          build_conn()
          |> Map.put(:remote_ip, {203, 0, 113, 99})
          |> post(~p"/login", %{
            "user" => %{"email" => "nobody@example.com", "password" => "wrong"}
          })
          |> Map.get(:status)
        end

      assert 429 in responses, "thirty sign-in attempts from one address were all allowed"
    end

    test "and a different address is not caught by somebody else's limit" do
      # A shared limit is a way for one attacker to lock everybody out.
      for _attempt <- 1..30 do
        build_conn()
        |> Map.put(:remote_ip, {203, 0, 113, 100})
        |> post(~p"/login", %{"user" => %{"email" => "a@example.com", "password" => "wrong"}})
      end

      status =
        build_conn()
        |> Map.put(:remote_ip, {198, 51, 100, 7})
        |> post(~p"/login", %{"user" => %{"email" => "b@example.com", "password" => "wrong"}})
        |> Map.get(:status)

      refute status == 429
    end
  end
end
