defmodule AbuubaWeb.FederationNotThrottledTest do
  @moduledoc """
  A peer server can dereference as much as federating requires.

  The federation surface used to sit in the `:api` pipeline, whose limiter
  counts anonymous requests per address, three hundred per five minutes. A
  peer dereferencing a busy thread makes hundreds of fetches from a handful
  of addresses -- so one lively peer starved itself, and the 429 landed on
  its webfinger lookups, which reads as this whole server being down. The
  interop suite is what noticed: half of GoToSocial's scenarios collapsed
  mid-block and recovered exactly when the five-minute window rolled.

  The reference implementation throttles only its /api paths and never the
  federation surface. The control at the bottom is the other half of that
  sentence: the limiter still has to hold where it belongs, or this test
  would pass on a server that had lost rate limiting entirely.
  """
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  @over_budget 350

  describe "what a peer fetches" do
    setup do
      account = account_fixture(%{username: "busy"})
      status = status_fixture(%{account_id: account.id, text: "much discussed"})

      %{account: account, status: status}
    end

    test "webfinger answers every time, however busy the peer", %{conn: conn} do
      statuses =
        for _ <- 1..@over_budget do
          conn
          |> get("/.well-known/webfinger?resource=acct:busy@localhost")
          |> Map.get(:status)
        end

      refute 429 in statuses, "a peer's webfinger was rate limited"
    end

    test "and so do the actor and the post", %{conn: conn, account: account, status: status} do
      statuses =
        for _ <- 1..@over_budget, path <- ["/users/busy", "/users/busy/statuses/#{status.id}"] do
          conn
          |> put_req_header("accept", "application/activity+json")
          |> get(path)
          |> Map.get(:status)
        end

      refute 429 in statuses, "a peer dereferencing was rate limited"
      assert 200 in statuses
      _ = account
    end
  end

  describe "while the API budget still holds" do
    test "an anonymous client is limited where it always was", %{conn: conn} do
      # The positive control: without it, the tests above would pass just as
      # well on a server whose rate limiting had quietly stopped existing.
      statuses =
        for _ <- 1..@over_budget do
          conn |> get("/api/v1/timelines/public") |> Map.get(:status)
        end

      assert 429 in statuses, "the API budget no longer limits anybody"
    end
  end
end
