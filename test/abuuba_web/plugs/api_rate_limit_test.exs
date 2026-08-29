defmodule AbuubaWeb.Plugs.APIRateLimitTest do
  @moduledoc """
  The headers a client is supposed to steer by.

  An endpoint with a narrow bucket of its own runs the limiter twice: once in
  the API pipeline for the general budget, once in the controller for its own.
  Both are charged, so the headers have to describe whichever of them the
  caller will actually hit first.
  """

  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.OAuth
  alias Abuuba.RateLimit

  @five_minutes 5 * 60 * 1000

  setup %{conn: conn} do
    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> raw),
      account: account,
      token: token
    }
  end

  describe "the rate-limit headers on an endpoint with two buckets" do
    test "describe the narrow bucket when it is the tighter one", %{
      conn: conn,
      account: account
    } do
      status = status_fixture(%{account_id: account.id, text: "mine"})

      response = delete(conn, "/api/v1/statuses/#{status.id}")

      # Nothing has been spent from the general budget, so the delete bucket's
      # thirty is what the caller is nearest to.
      assert get_resp_header(response, "x-ratelimit-limit") == ["30"]
      assert get_resp_header(response, "x-ratelimit-remaining") == ["29"]
    end

    test "describe the general budget when that one is tighter", %{
      conn: conn,
      account: account,
      token: token
    } do
      # Spent through the counter rather than through 290 requests: the point
      # under test is which numbers come back, not how they got there.
      spend("api:token:#{token.id}", 295, 300)

      status = status_fixture(%{account_id: account.id, text: "mine"})

      response = delete(conn, "/api/v1/statuses/#{status.id}")

      # The delete bucket has 29 of 30 left and the token has 4 of 300. Telling
      # the client 29 would have it carry on until a 429 the headers never
      # warned about, which is exactly what a well-behaved client cannot
      # recover from gracefully.
      assert get_resp_header(response, "x-ratelimit-limit") == ["300"]
      assert get_resp_header(response, "x-ratelimit-remaining") == ["4"]
    end
  end

  defp spend(key, times, limit) do
    for _ <- 1..times, do: RateLimit.take(key, limit: limit, window_ms: @five_minutes)

    :ok
  end
end
