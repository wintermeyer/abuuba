defmodule AbuubaWeb.API.StreamingControllerTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.OAuth
  alias Abuuba.Settings
  alias AbuubaWeb.Streaming.Filter
  alias AbuubaWeb.Streaming.Subscription

  setup %{conn: conn} do
    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read"])

    %{conn: conn, token: raw, account: account}
  end

  describe "health" do
    test "answers plainly, which is what a load balancer asks", %{conn: conn} do
      conn = get(conn, "/api/v1/streaming/health")

      assert response(conn, 200) == "OK"
    end
  end

  describe "the socket state a request builds" do
    test "reads a token from the Authorization header", %{
      conn: conn,
      token: token,
      account: account
    } do
      state =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> Plug.Conn.fetch_query_params()
        |> AbuubaWeb.StreamingSocket.connect()

      assert state.account.id == account.id
    end

    test "reads one from the query string, which is all a browser can do", %{
      conn: conn,
      token: token,
      account: account
    } do
      state =
        %{conn | query_string: "access_token=#{token}"}
        |> Plug.Conn.fetch_query_params()
        |> AbuubaWeb.StreamingSocket.connect()

      assert state.account.id == account.id
    end

    test "reads one smuggled through Sec-WebSocket-Protocol", %{
      conn: conn,
      token: token,
      account: account
    } do
      state =
        conn
        |> put_req_header("sec-websocket-protocol", token <> ", other")
        |> Plug.Conn.fetch_query_params()
        |> AbuubaWeb.StreamingSocket.connect()

      assert state.account.id == account.id
    end

    test "a stream with nobody behind it is still a stream", %{conn: conn} do
      # An anonymous viewer of a public page is doing exactly this.
      state = conn |> Plug.Conn.fetch_query_params() |> AbuubaWeb.StreamingSocket.connect()

      assert state.account == nil
      assert state.scopes == []
    end
  end

  describe "server-sent events" do
    test "a stream nobody defined is not there", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/streaming/nonsense"), 404)["error"]
    end

    test "a personal stream needs a token", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/streaming/user"), 404)["error"]
    end

    test "a server announcement reaches this stream too", %{conn: conn, token: token} do
      # The websocket subscribes a signed-in client to announcements; this door
      # did not, so a notice from the people running the server reached one
      # kind of client and not the other.
      #
      # Readable only because revoking closes the stream: an event stream that
      # is working never returns, so the frames it wrote are collected by
      # ending it on purpose.
      authed = put_req_header(conn, "authorization", "Bearer " <> token)

      stream = Task.async(fn -> get(authed, "/api/v1/streaming/user") end)

      Process.sleep(300)

      {:ok, announcement} =
        Abuuba.Instance.create_announcement(%{text: "the server moves house", published: true})

      Abuuba.Streaming.publish_announcement(announcement)

      Process.sleep(300)
      :ok = token |> OAuth.get_token() |> OAuth.revoke_token()

      assert {:ok, conn} = Task.yield(stream, 5_000)
      assert conn.resp_body =~ "announcement"
      assert conn.resp_body =~ "the server moves house"
    end

    test "revoking the token closes a stream that is already open", %{conn: conn, token: token} do
      # "Sign out everywhere" has to mean the stream too. Authentication
      # happens once, at connect, and nothing afterwards re-reads the token, so
      # without this a revoked one goes on delivering posts and notifications
      # until the client happens to hang up -- and a stream is the connection
      # most likely to still be open. The websocket half has closed on this
      # since it was written; this door did not.
      authed = put_req_header(conn, "authorization", "Bearer " <> token)

      stream = Task.async(fn -> get(authed, "/api/v1/streaming/user") end)

      # Long enough for the request to reach the subscribe, short enough that a
      # failure here is quick.
      Process.sleep(300)

      :ok = token |> OAuth.get_token() |> OAuth.revoke_token()

      assert {:ok, _conn} = Task.yield(stream, 5_000),
             "the stream is still open after the token was revoked"
    end

    test "the public stream is closed to a stranger when the timelines are", %{conn: conn} do
      # An admin who sets the timelines to members-only has said strangers do
      # not read this server. The API refuses them, the front page refuses
      # them, and this stream went on pushing the same posts to anybody who
      # opened it.
      Settings.put("timeline_access", "authenticated")

      # 401 rather than 404: the stream exists, and for `authenticated` the
      # honest answer is that this reader needs an account here.
      assert json_response(get(conn, "/api/v1/streaming/public"), 401)["error"]
    end

    test "and the websocket door answers the same", %{conn: conn} do
      # Two files carry this decision, one per transport, and they spell the
      # stream names differently. Fixing one is fixing half.
      Settings.put("timeline_access", "authenticated")

      state = %{account: nil, scopes: [], topics: MapSet.new(), token_id: nil, params: %{}}
      frame = ~s({"type":"subscribe","stream":"public"})

      {:ok, state} = AbuubaWeb.StreamingSocket.handle_in({frame, []}, state)

      assert MapSet.size(state.topics) == 0
      assert conn
    end

    test "and both stay open when the timelines are", %{conn: conn} do
      # The control: refusing every public stream would satisfy both tests
      # above. Checked on the websocket rather than over SSE, because an open
      # event stream never returns.
      Settings.put("timeline_access", "public")

      state = %{account: nil, scopes: [], topics: MapSet.new(), token_id: nil, params: %{}}
      frame = ~s({"type":"subscribe","stream":"public"})

      {:ok, state} = AbuubaWeb.StreamingSocket.handle_in({frame, []}, state)

      assert MapSet.size(state.topics) == 1
      assert conn
    end
  end

  describe "the websocket sets up the same way" do
    # The shared half lives in `Abuuba.Streaming.subscribe_connection/1` so a
    # thing added for one transport reaches both. Both halves need a test, or
    # breaking it shows up on one door only and looks like a bug in that door.
    #
    # `init/1` subscribes whichever process calls it, which here is the test,
    # so a broadcast afterwards arrives in this mailbox.
    setup %{account: account, token: token} do
      access = OAuth.get_token(token)

      %{
        state: %{
          account: account,
          token_id: access.id,
          scopes: ["read"],
          topics: MapSet.new(),
          params: %{}
        }
      }
    end

    test "it hears that its token was revoked", %{state: state, token: token} do
      {:ok, _state} = AbuubaWeb.StreamingSocket.init(state)

      :ok = token |> OAuth.get_token() |> OAuth.revoke_token()

      assert_receive {:streaming, :revoked}, 2_000
    end

    test "and it hears a server announcement", %{state: state} do
      {:ok, _state} = AbuubaWeb.StreamingSocket.init(state)

      {:ok, announcement} =
        Abuuba.Instance.create_announcement(%{text: "a notice for everybody", published: true})

      Abuuba.Streaming.publish_announcement(announcement)

      assert_receive {:streaming, "announcement", _payload}, 2_000
    end
  end

  describe "one table of streams, for both transports" do
    # The two transports each carried their own copy: the socket knew the
    # media streams and `list`, the SSE side knew neither and spelled two of
    # its own with a slash. `AbuubaWeb.Streaming.Filter` matches on the name,
    # and ended in a catch-all `true` -- so a name it did not recognise let
    # every post through. These hold the three against each other.
    setup %{account: account} do
      %{state: %{account: account, scopes: [:read], topics: MapSet.new(), token_id: nil}}
    end

    test "every stream it advertises resolves to a topic", %{state: state} do
      for stream <- Subscription.streams() do
        assert {:ok, ^stream, _topic} =
                 Subscription.topic_for(stream, %{"tag" => "cats"}, state),
               "#{stream} is in the table and cannot be subscribed to"
      end
    end

    test "and Filter answers each of them deliberately", %{account: account} do
      # The table, written out. One local public post with no media, offered
      # to every stream in turn: what matters is that nothing answers by
      # accident, which is what the catch-all `true` used to arrange.
      status = status_fixture(%{account_id: account.id, visibility: :public})

      carries = ~w(user public public:local hashtag hashtag:local list)
      ignores = ~w(user:notification direct public:remote)
      no_media = ~w(public:media public:local:media public:remote:media)

      assert Enum.sort(carries ++ ignores ++ no_media) == Enum.sort(Subscription.streams()),
             "a stream was added without saying what it does with a post"

      for stream <- carries do
        assert {:ok, _frame} = offer(status, account, stream), "#{stream} dropped a post"
      end

      for stream <- ignores ++ no_media do
        assert offer(status, account, stream) == :skip, "#{stream} carried a post it should not"
      end
    end

    defp offer(status, account, stream) do
      Filter.for_viewer("update", status, %{
        account: account,
        scopes: [:read],
        topics: MapSet.new([{stream, "t"}]),
        token_id: nil
      })
    end

    test "a stream nobody wrote a rule for carries nothing", %{account: account} do
      status = status_fixture(%{account_id: account.id, visibility: :public})

      assert offer(status, account, "public/local") == :skip,
             "the catch-all used to answer `true` here, which is every post"
    end

    test "the slash spelling reaches the stream it meant", %{state: state} do
      # Kept working, and normalised: a client that used it was reaching a
      # real stream, and what it stores is what Filter is keyed on.
      assert {:ok, "public:local", topic} = Subscription.topic_for("public/local", %{}, state)
      assert {:ok, "public:local", ^topic} = Subscription.topic_for("public:local", %{}, state)
    end
  end

  describe "which scope a stream needs" do
    test "the personal ones need one and the public ones do not" do
      alias AbuubaWeb.Streaming.Payload

      assert Payload.required_scope("user") == "read:statuses"
      assert Payload.required_scope("user:notification") == "read:notifications"
      assert Payload.required_scope("public") == nil
      assert Payload.required_scope("hashtag") == nil
    end
  end
end
