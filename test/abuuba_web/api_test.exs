defmodule AbuubaWeb.APITest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.OAuth
  alias Abuuba.RateLimit
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Pagination
  alias AbuubaWeb.Plugs.RequireUser
  alias Plug.Conn.Query

  setup do
    RateLimit.reset()
    :ok
  end

  describe "ids on the wire" do
    test "are strings, because a JavaScript client cannot hold them otherwise" do
      # Past 2^53 a JSON number loses its low bits, so two different posts
      # start comparing equal in the client.
      assert API.id(117_044_107_826_612_036) == "117044107826612036"
    end

    test "a string stays one, and nothing stays nothing" do
      assert API.id("42") == "42"
      assert API.id(nil) == nil
    end
  end

  describe "reading an id out of a query" do
    test "accepts the string a client sends" do
      assert API.id_param(%{"max_id" => "117044107826612036"}, "max_id") ==
               117_044_107_826_612_036
    end

    test "treats nonsense as absent rather than as an error" do
      # Clients send `max_id=` with nothing after it often enough that refusing
      # would break paging for them.
      assert API.id_param(%{"max_id" => ""}, "max_id") == nil
      assert API.id_param(%{"max_id" => "nope"}, "max_id") == nil
      assert API.id_param(%{}, "max_id") == nil
    end
  end

  describe "whether a flag means yes" do
    test "the values the reference calls no, and nothing else" do
      # `ActiveModel::Type::Boolean` is what `truthy_param?` casts with, and
      # its false set is these plus their capitalisations. Everything else a
      # client sends is yes.
      for no <- [false, 0, "0", "f", "F", "false", "FALSE", "off", "OFF", nil] do
        refute API.truthy?(no), "#{inspect(no)} should be no"
      end

      for yes <- [true, 1, "1", "true", "TRUE", "on", "yes", "banana"] do
        assert API.truthy?(yes), "#{inspect(yes)} should be yes"
      end
    end

    test "which is a denylist, and used to be two functions disagreeing" do
      # `AbuubaWeb.API.AccountController` carried its own, the other way round:
      # an allowlist here said `"on"` was no while its denylist said `"f"` was
      # yes, so the same word meant opposite things on two endpoints.
      assert API.truthy?("on")
      refute API.truthy?("f")
    end
  end

  describe "how many records a request asked for" do
    test "the default when it did not ask" do
      assert API.limit(%{}, 20) == 20
    end

    test "what it asked for, when that is reasonable" do
      assert API.limit(%{"limit" => "5"}, 20) == 5
    end

    test "clamped rather than refused when it is not" do
      assert API.limit(%{"limit" => "5000"}, 20) == 40
      assert API.limit(%{"limit" => "-1"}, 20) == 1
      # Zero means an empty page, which is what the reference implementation
      # gives a client that asks for one.
      assert API.limit(%{"limit" => "0"}, 20) == 0
      assert API.limit(%{"limit" => "banana"}, 20) == 20
    end

    test "a caller may raise the ceiling" do
      assert API.limit(%{"limit" => "80"}, 20, 80) == 80
    end
  end

  describe "pagination parameters" do
    test "max_id and since_id read newest first" do
      params = Pagination.params(%{"max_id" => "100", "since_id" => "50"})

      assert params.max_id == 100
      assert params.since_id == 50
      assert params.order == :desc
    end

    test "min_id reads oldest first, which is the whole reason it exists" do
      # With since_id and a gap of five hundred posts a client asking for
      # twenty gets the twenty newest and never sees the rest. With min_id it
      # gets the twenty oldest it is missing and can walk forward.
      params = Pagination.params(%{"min_id" => "50"})

      assert params.min_id == 50
      assert params.order == :asc
    end
  end

  # What a client gets when it follows the link, rather than what the header
  # looks like. The two differ exactly where the bugs were.
  defp followed(header) do
    [target] = Regex.run(~r/<([^>]+)>; rel="next"/, header, capture: :all_but_first)

    target |> URI.parse() |> Map.get(:query) |> Query.decode()
  end

  describe "the Link header" do
    test "points next at older and prev at newer", %{conn: conn} do
      conn = %{conn | request_path: "/api/v1/timelines/home", query_params: %{}}

      [link] =
        conn
        |> Pagination.put_link_header([%{id: 30}, %{id: 20}, %{id: 10}])
        |> get_resp_header("link")

      assert link =~ ~s(max_id=10>; rel="next")
      assert link =~ ~s(min_id=30>; rel="prev")
    end

    test "is absent entirely on an empty page", %{conn: conn} do
      # A next link pointing at nothing tells a client to keep asking, and
      # that is how a paging loop fails to end.
      assert Pagination.put_link_header(conn, []) |> get_resp_header("link") == []
    end

    test "writes a repeated parameter back out repeated", %{conn: conn} do
      # `?any[]=a&any[]=b` arrives as a list, which the query encoder refuses.
      # The link a client follows has to carry the same filters the request did
      # -- read back rather than matched as text, because `any=a&any=b` looks
      # right and decodes to just `b`, which is the whole bug this catches: a
      # hashtag timeline that quietly forgets a tag on the second page.
      conn = %{
        conn
        | request_path: "/api/v1/timelines/tag/cats",
          query_params: %{"any" => ["a", "b"]}
      }

      [link] = conn |> Pagination.put_link_header([%{id: 10}]) |> get_resp_header("link")

      assert followed(link)["any"] == ["a", "b"]
    end

    test "and a numbered one back out numbered", %{conn: conn} do
      # `?any[0]=a&any[1]=b` arrives as a map keyed by the index, and the
      # encoder was handed it whole: `to_string` on a map raises, so the page
      # was built and then died on the way out with a 500.
      #
      # It goes back out numbered rather than converted, because the link has
      # to ask the same question the request did and both spellings are read
      # the same way now. Rewriting it would be tidier and would tell the
      # client something about its own request that is not true.
      conn = %{
        conn
        | request_path: "/api/v1/timelines/tag/cats",
          query_params: %{"any" => %{"0" => "a", "1" => "b"}}
      }

      [link] = conn |> Pagination.put_link_header([%{id: 10}]) |> get_resp_header("link")

      assert followed(link)["any"] == %{"0" => "a", "1" => "b"}
    end

    test "and keeps a nested parameter nested", %{conn: conn} do
      conn = %{
        conn
        | request_path: "/api/v1/timelines/tag/cats",
          query_params: %{"poll" => %{"expires_in" => "3600"}}
      }

      [link] = conn |> Pagination.put_link_header([%{id: 10}]) |> get_resp_header("link")

      assert followed(link)["poll"] == %{"expires_in" => "3600"}
    end

    test "keeps the rest of the query and drops the old cursor", %{conn: conn} do
      conn = %{
        conn
        | request_path: "/api/v1/timelines/public",
          query_params: %{"local" => "true", "max_id" => "99"}
      }

      [link] = conn |> Pagination.put_link_header([%{id: 10}]) |> get_resp_header("link")

      assert link =~ "local=true"
      assert link =~ "max_id=10"
      refute link =~ "max_id=99"
    end
  end

  describe "an endpoint that needs a person behind it" do
    test "answers 422 with no token at all, not 401", %{conn: conn} do
      # 401 makes an app discard the token it holds and send the person back
      # through the whole OAuth flow. Answering it here would log people out of
      # an app that was working a moment earlier.
      conn = conn |> Plug.Conn.assign(:current_scope, %{user: nil}) |> RequireUser.call([])

      assert conn.status == 422
      assert json_response(conn, 422)["error"] =~ "authenticated user"
    end

    test "answers 403 for an address nobody confirmed", %{conn: conn} do
      user = user_fixture(%{confirmed_at: nil})

      conn = conn |> Plug.Conn.assign(:current_scope, %{user: user}) |> RequireUser.call([])

      assert json_response(conn, 403)["error"] =~ "confirmed e-mail"
    end

    test "answers 403 while an account is waiting for approval", %{conn: conn} do
      user = user_fixture(%{approved: false, confirmed_at: DateTime.utc_now()})

      conn = conn |> Plug.Conn.assign(:current_scope, %{user: user}) |> RequireUser.call([])

      assert json_response(conn, 403)["error"] =~ "pending approval"
    end

    test "answers 403 for a suspended account", %{conn: conn} do
      account = account_fixture()

      {:ok, account} =
        Abuuba.Accounts.update_moderation(account, %{suspended_at: DateTime.utc_now()})

      user =
        user_fixture(%{
          account_id: account.id,
          approved: true,
          confirmed_at: DateTime.utc_now()
        })

      user = %{user | account: account}

      conn = conn |> Plug.Conn.assign(:current_scope, %{user: user}) |> RequireUser.call([])

      assert json_response(conn, 403)["error"] =~ "disabled"
    end

    test "refuses when it cannot tell whether the account is suspended", %{conn: conn} do
      # The account is preloaded on the one path that produces a token. If a
      # later caller ever forgets, "we could not check" has to mean "no": the
      # alternative is a suspended account acting through an unlucky code path.
      user =
        user_fixture(%{approved: true, confirmed_at: DateTime.utc_now()})

      refute match?(%Abuuba.Accounts.Account{}, user.account)

      conn = conn |> Plug.Conn.assign(:current_scope, %{user: user}) |> RequireUser.call([])

      assert json_response(conn, 403)["error"] =~ "disabled"
    end

    test "lets a working account through", %{conn: conn} do
      account = account_fixture()

      user =
        user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

      user = %{user | account: account}

      conn = conn |> Plug.Conn.assign(:current_scope, %{user: user}) |> RequireUser.call([])

      refute conn.halted
      refute conn.status
    end
  end

  describe "rate limit headers" do
    test "are on an ordinary API response", %{conn: conn} do
      conn = get(conn, "/api/v1/instance")

      assert [limit] = get_resp_header(conn, "x-ratelimit-limit")
      assert [remaining] = get_resp_header(conn, "x-ratelimit-remaining")
      assert [reset] = get_resp_header(conn, "x-ratelimit-reset")

      assert String.to_integer(remaining) < String.to_integer(limit)
      assert {:ok, _at, _offset} = DateTime.from_iso8601(reset)
    end

    test "count an anonymous caller by address", %{conn: conn} do
      first = get(conn, "/api/v1/instance")
      second = get(build_conn(), "/api/v1/instance")

      assert [one] = get_resp_header(first, "x-ratelimit-remaining")
      assert [two] = get_resp_header(second, "x-ratelimit-remaining")
      assert String.to_integer(two) == String.to_integer(one) - 1
    end

    test "count an authenticated caller against their account, not their address" do
      # One person with six apps has one budget, and moving to a new address
      # does not reset it.
      %{token: raw} = api_token()

      first = build_conn() |> authorize(raw) |> get("/api/v1/instance")
      second = build_conn() |> authorize(raw) |> get("/api/v1/instance")

      assert [one] = get_resp_header(first, "x-ratelimit-remaining")
      assert [two] = get_resp_header(second, "x-ratelimit-remaining")
      assert String.to_integer(two) == String.to_integer(one) - 1
    end

    test "describe whichever bucket is closest to running out" do
      # An authenticated request counts against the account and the token. The
      # token's is the smaller, so that is the one a client will hit.
      %{token: raw} = api_token()

      conn = build_conn() |> authorize(raw) |> get("/api/v1/instance")

      assert get_resp_header(conn, "x-ratelimit-limit") == ["300"]
    end

    test "do not count a preflight", %{conn: conn} do
      # A browser preflights before every request it cannot send simply.
      # Counting both would halve the budget of every web client, and the
      # preflight is not a request for anything.
      before = conn |> get("/api/v1/instance") |> remaining()

      options(build_conn(), "/api/v1/instance")
      options(build_conn(), "/api/v1/instance")

      assert remaining(get(build_conn(), "/api/v1/instance")) == before - 1
    end

    test "refuse an over-eager app registration with JSON, not a crash", %{conn: conn} do
      # This route is JSON with no session, so a refusal that tries to set a
      # flash and redirect raises instead of answering.
      for _ <- 1..6 do
        post(build_conn(), "/api/v1/apps", %{"client_name" => "x", "redirect_uris" => "urn:x"})
      end

      conn = post(conn, "/api/v1/apps", %{"client_name" => "x", "redirect_uris" => "urn:x"})

      assert conn.status == 429
      assert json_response(conn, 429)["error"]
    end

    test "refuse with 429 once the bucket is empty", %{conn: conn} do
      for _ <- 1..300, do: RateLimit.hit("api:ip:127.0.0.1", limit: 300, window_ms: 300_000)

      conn = get(conn, "/api/v1/instance")

      assert json_response(conn, 429)["error"] =~ "Too many"
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["0"]
    end
  end

  describe "cross-origin access" do
    test "any origin may read the API", %{conn: conn} do
      conn = conn |> put_req_header("origin", "https://app.example") |> get("/api/v1/instance")

      assert get_resp_header(conn, "access-control-allow-origin") == ["https://app.example"]
    end

    test "exposes the headers a client cannot work without", %{conn: conn} do
      # A browser hides every response header from JavaScript but a short safe
      # list, so a client that cannot read Link cannot page and one that cannot
      # read X-RateLimit-Reset cannot back off.
      conn = get(conn, "/api/v1/instance")

      assert [exposed] = get_resp_header(conn, "access-control-expose-headers")

      for header <-
            ~w(Link X-RateLimit-Limit X-RateLimit-Remaining X-RateLimit-Reset X-Request-Id) do
        assert exposed =~ header
      end
    end

    test "says the answer depends on the origin too", %{conn: conn} do
      # The allow-origin header is echoed from the request, so a shared cache
      # that ignores Origin would hand one site's response to another.
      conn = conn |> put_req_header("origin", "https://app.example") |> get("/api/v1/instance")

      assert [vary] = get_resp_header(conn, "vary")
      assert vary =~ "Origin"
    end

    test "says the answer depends on who asked", %{conn: conn} do
      # The same URL answers differently per token, and a cache that does not
      # know that serves one person's timeline to the next.
      conn = get(conn, "/api/v1/instance")

      assert [vary] = get_resp_header(conn, "vary")
      assert vary =~ "Authorization"
    end

    test "are on a 404 too, so a browser can read the answer", %{conn: conn} do
      # A pipeline only runs once a route has matched. Without these on the
      # miss, a browser client sees an opaque network error rather than the
      # 404 it could have handled.
      conn = conn |> put_req_header("origin", "https://app.example") |> get("/api/v1/nope")

      assert conn.status == 404
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://app.example"]
    end

    test "answers a preflight without reaching the endpoint", %{conn: conn} do
      # A preflight carries no token, so anything behind authentication would
      # refuse it and the real request would never be sent.
      conn = options(conn, "/api/v1/instance")

      assert conn.status == 204
      assert [methods] = get_resp_header(conn, "access-control-allow-methods")
      assert methods =~ "POST"
    end
  end

  defp remaining(conn) do
    [value] = get_resp_header(conn, "x-ratelimit-remaining")
    String.to_integer(value)
  end

  defp api_token do
    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read"])

    %{token: raw, user: user, account: account}
  end

  defp authorize(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)
end
