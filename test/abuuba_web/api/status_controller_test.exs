defmodule AbuubaWeb.API.StatusControllerTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Instance
  alias Abuuba.Media
  alias Abuuba.Media.Attachment
  alias Abuuba.OAuth
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Statuses
  alias Abuuba.Statuses.ScheduledStatus
  alias Abuuba.Statuses.Status
  alias AbuubaWeb.API.Entities

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
      account: account,
      application: application
    }
  end

  defp attachment_fixture(account) do
    Repo.insert!(%Attachment{
      account_id: account.id,
      type: :image,
      processing: :complete,
      file_file_name: "picture.png",
      file_content_type: "image/png",
      file_file_size: 100,
      remote_url: ""
    })
  end

  defp token_for(application, account) do
    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    put_req_header(build_conn(), "authorization", "Bearer " <> raw)
  end

  describe "posting" do
    test "creates a status and hands it back rendered", %{conn: conn} do
      conn = post(conn, "/api/v1/statuses", %{"text" => "hello world"})

      body = json_response(conn, 200)

      assert body["content"] == "<p>hello world</p>"
      assert body["visibility"] == "public"
      assert is_binary(body["id"])
    end

    test "takes the text under the name every client sends it by", %{conn: conn} do
      # `status` is what the documented parameter is called, and what every
      # written client sends. Reading only `text` here made the endpoint answer
      # 200 with an empty post, which is worse than refusing it: the client
      # believes it posted.
      body = json_response(post(conn, "/api/v1/statuses", %{"status" => "hello world"}), 200)

      assert body["content"] == "<p>hello world</p>"
    end

    test "prefers an explicit text over status when a client sends both", %{conn: conn} do
      body =
        json_response(
          post(conn, "/api/v1/statuses", %{"status" => "one", "text" => "the other"}),
          200
        )

      assert body["content"] == "<p>the other</p>"
    end

    test "refuses a post with nothing in it", %{conn: conn} do
      # 200 here is the worst answer available: the client shows the post as
      # sent and the person finds an empty one later.
      for params <- [%{}, %{"status" => ""}, %{"status" => nil}] do
        assert json_response(post(conn, "/api/v1/statuses", params), 422)["error"] =~ "blank"
      end
    end

    test "needs somebody signed in, and says so with 422", %{anon: anon} do
      # Not 401: that makes an app throw away its token and restart the whole
      # OAuth flow, which would log people out of an app that was working.
      conn = post(anon, "/api/v1/statuses", %{"text" => "hello"})

      assert json_response(conn, 422)["error"] =~ "authenticated user"
    end

    test "refuses a post longer than a post", %{conn: conn} do
      conn = post(conn, "/api/v1/statuses", %{"text" => String.duplicate("a", 600)})

      assert json_response(conn, 422)["error"] =~ "Validation failed"
    end

    test "answers a retry with the post it already made", %{conn: conn} do
      # The client timed out and cannot tell whether the first one landed.
      # Without this its retry is a second post.
      first =
        conn
        |> put_req_header("idempotency-key", "abc-123")
        |> post("/api/v1/statuses", %{"text" => "once"})
        |> json_response(200)

      second =
        conn
        |> put_req_header("idempotency-key", "abc-123")
        |> post("/api/v1/statuses", %{"text" => "once"})
        |> json_response(200)

      assert first["id"] == second["id"]
      assert Repo.aggregate(Status, :count) == 1
    end

    test "and a retry of a scheduled post with the scheduled post", %{conn: conn} do
      # The key was threaded all the way into the scheduling branch and then
      # dropped on the floor, so a client that timed out scheduling something
      # got two of them -- and unlike a duplicate post, nobody sees the second
      # one until it goes out.
      at = DateTime.utc_now() |> DateTime.add(2, :hour) |> DateTime.to_iso8601()

      first =
        conn
        |> put_req_header("idempotency-key", "sched-1")
        |> post("/api/v1/statuses", %{"text" => "later", "scheduled_at" => at})
        |> json_response(200)

      second =
        conn
        |> put_req_header("idempotency-key", "sched-1")
        |> post("/api/v1/statuses", %{"text" => "later", "scheduled_at" => at})
        |> json_response(200)

      assert first["id"] == second["id"]
      assert first["scheduled_at"]
      assert Repo.aggregate(ScheduledStatus, :count) == 1
    end

    test "a different key is a different post", %{conn: conn} do
      one =
        conn
        |> put_req_header("idempotency-key", "a")
        |> post("/api/v1/statuses", %{"text" => "x"})

      two =
        conn
        |> put_req_header("idempotency-key", "b")
        |> post("/api/v1/statuses", %{"text" => "x"})

      refute json_response(one, 200)["id"] == json_response(two, 200)["id"]
    end
  end

  describe "posting with pictures and polls" do
    test "attaches the media the client uploaded", %{conn: conn, account: account} do
      one = attachment_fixture(account)
      two = attachment_fixture(account)

      body =
        json_response(
          post(conn, "/api/v1/statuses", %{
            "status" => "look at these",
            "media_ids" => [to_string(one.id), to_string(two.id)]
          }),
          200
        )

      assert [%{"id" => first}, %{"id" => second}] = body["media_attachments"]
      assert first == to_string(one.id)
      assert second == to_string(two.id)

      # The order is the author's, not the table's.
      assert Repo.reload!(one).status_id == String.to_integer(body["id"])
    end

    test "including when the client numbered them", %{conn: conn, account: account} do
      # `media_ids[0]=x` is a map keyed by the index by the time it reaches the
      # controller, and reading only the list answered "one of those uploads is
      # not yours to post" -- which is not what went wrong, and sends whoever
      # reads it looking at permissions.
      one = attachment_fixture(account)
      two = attachment_fixture(account)

      body =
        json_response(
          post(conn, "/api/v1/statuses", %{
            "status" => "numbered",
            "media_ids" => %{"1" => to_string(two.id), "0" => to_string(one.id)}
          }),
          200
        )

      assert Enum.map(body["media_attachments"], & &1["id"]) ==
               [to_string(one.id), to_string(two.id)]
    end

    test "and one as long as the instance endpoint says it may be", %{conn: conn} do
      # The advertised maximum was a literal of its own, six times shorter than
      # what this endpoint accepts, so a client offering the longest poll it
      # had been told about withheld five months of it. Read from the endpoint
      # rather than from the constant, because the promise is what a client
      # reads and the clamp is what it gets.
      advertised =
        conn
        |> get("/api/v2/instance")
        |> json_response(200)
        |> get_in(["configuration", "polls", "max_expiration"])

      # Asked for ten times the advertised maximum, so the answer is whatever
      # the server's own ceiling is. That catches the promise being too small
      # as well as too large: either way the two numbers have to be one.
      body =
        json_response(
          post(conn, "/api/v1/statuses", %{
            "status" => "a long question",
            "poll" => %{"options" => ["yes", "no"], "expires_in" => advertised * 10}
          }),
          200
        )

      {:ok, expires_at, _} = DateTime.from_iso8601(body["poll"]["expires_at"])

      assert_in_delta DateTime.diff(expires_at, DateTime.utc_now()),
                      advertised,
                      60,
                      "what the endpoint offers is not what the server accepts"
    end

    test "and a poll whose options are numbered", %{conn: conn} do
      # Same shape, and the same kind of answer: "a poll needs at least two
      # options" for a request that sent two.
      body =
        json_response(
          post(conn, "/api/v1/statuses", %{
            "status" => "pick one",
            "poll" => %{
              "options" => %{"0" => "yes", "1" => "no"},
              "expires_in" => "3600"
            }
          }),
          200
        )

      assert Enum.map(body["poll"]["options"], & &1["title"]) == ["yes", "no"]
    end

    test "keeps the order the ids were given in", %{conn: conn, account: account} do
      one = attachment_fixture(account)
      two = attachment_fixture(account)

      body =
        json_response(
          post(conn, "/api/v1/statuses", %{
            "status" => "back to front",
            "media_ids" => [to_string(two.id), to_string(one.id)]
          }),
          200
        )

      assert Enum.map(body["media_attachments"], & &1["id"]) ==
               [to_string(two.id), to_string(one.id)]
    end

    test "lets a post be pictures and nothing else", %{conn: conn, account: account} do
      one = attachment_fixture(account)

      body =
        json_response(
          post(conn, "/api/v1/statuses", %{"media_ids" => [to_string(one.id)]}),
          200
        )

      # A picture is something said. The emptiness check has to know that.
      assert [_attachment] = body["media_attachments"]
    end

    test "refuses somebody else's upload", %{conn: conn} do
      theirs = attachment_fixture(account_fixture())

      assert json_response(
               post(conn, "/api/v1/statuses", %{
                 "status" => "not mine",
                 "media_ids" => [to_string(theirs.id)]
               }),
               422
             )["error"]

      # And writes nothing: a post that appeared without its pictures would
      # look to its author like the upload failed silently.
      assert Repo.aggregate(Status, :count) == 0
    end

    test "refuses one already on another post", %{conn: conn, account: account} do
      attachment = attachment_fixture(account)

      post(conn, "/api/v1/statuses", %{
        "status" => "first",
        "media_ids" => [to_string(attachment.id)]
      })

      assert json_response(
               post(conn, "/api/v1/statuses", %{
                 "status" => "again",
                 "media_ids" => [to_string(attachment.id)]
               }),
               422
             )["error"]
    end

    test "refuses more than the server allows", %{conn: conn, account: account} do
      ids =
        for _ <- 1..(Instance.max_media_attachments() + 1),
            do: to_string(attachment_fixture(account).id)

      assert json_response(
               post(conn, "/api/v1/statuses", %{"status" => "too many", "media_ids" => ids}),
               422
             )["error"]
    end

    test "creates the poll a client asked for", %{conn: conn} do
      body =
        json_response(
          post(conn, "/api/v1/statuses", %{
            "status" => "which one",
            "poll" => %{"options" => ["this", "that"], "expires_in" => "3600"}
          }),
          200
        )

      assert %{"options" => [%{"title" => "this"}, %{"title" => "that"}]} = body["poll"]
      assert body["poll"]["expires_at"]
    end

    test "makes a multiple-choice poll when asked", %{conn: conn} do
      body =
        json_response(
          post(conn, "/api/v1/statuses", %{
            "status" => "pick some",
            "poll" => %{
              "options" => ["a", "b"],
              "expires_in" => "3600",
              "multiple" => "true"
            }
          }),
          200
        )

      assert body["poll"]["multiple"]
    end

    test "refuses a poll with one option and writes nothing", %{conn: conn} do
      assert json_response(
               post(conn, "/api/v1/statuses", %{
                 "status" => "not a question",
                 "poll" => %{"options" => ["only this"], "expires_in" => "3600"}
               }),
               422
             )["error"]

      assert Repo.aggregate(Status, :count) == 0
    end

    test "writes nothing when the poll options are refused", %{conn: conn} do
      # The count check is not the whole of what a poll has to be. Blank,
      # duplicate and over-long options are refused by the changeset, and each
      # one used to leave a published post behind that its author had been
      # told was refused.
      for options <- [["same", "same"], ["a", "   "], ["a", String.duplicate("x", 51)]] do
        assert json_response(
                 post(conn, "/api/v1/statuses", %{
                   "status" => "a question",
                   "poll" => %{"options" => options, "expires_in" => "3600"}
                 }),
                 422
               )["error"]
      end

      assert Repo.aggregate(Status, :count) == 0
    end

    test "does not publish a post whose pictures it then refuses", %{conn: conn} do
      theirs = attachment_fixture(account_fixture())

      assert json_response(
               post(conn, "/api/v1/statuses", %{
                 "status" => "not mine",
                 "media_ids" => [to_string(theirs.id)]
               }),
               422
             )["error"]

      assert Repo.aggregate(Status, :count) == 0
      refute Repo.reload!(theirs).status_id
    end

    test "counts the same picture once", %{conn: conn, account: account} do
      attachment = attachment_fixture(account)

      body =
        json_response(
          post(conn, "/api/v1/statuses", %{
            "status" => "twice",
            "media_ids" => [to_string(attachment.id), to_string(attachment.id)]
          }),
          200
        )

      assert [_one] = body["media_attachments"]
    end

    test "keeps a poll's life within the bounds a poll may have", %{conn: conn} do
      body =
        json_response(
          post(conn, "/api/v1/statuses", %{
            "status" => "already over?",
            "poll" => %{"options" => ["a", "b"], "expires_in" => "-100"}
          }),
          200
        )

      # A negative expiry produced a poll that was closed before anybody saw
      # it; an enormous one produced a poll expiring in the year 33715.
      refute body["poll"]["expired"]

      far =
        json_response(
          post(conn, "/api/v1/statuses", %{
            "status" => "forever?",
            "poll" => %{"options" => ["a", "b"], "expires_in" => "999999999999"}
          }),
          200
        )

      {:ok, expires_at, _offset} = DateTime.from_iso8601(far["poll"]["expires_at"])
      assert DateTime.diff(expires_at, DateTime.utc_now(), :day) <= 190
    end

    test "the post that reaches everybody already has its pictures on it", %{
      account: account
    } do
      one = attachment_fixture(account)
      two = attachment_fixture(account)

      # `announce/1` — the feeds, the streaming API, the outbox — is handed
      # whatever `create_status` returns. Attaching afterwards handed it a
      # photo post with no photographs, which also kept it out of the media
      # streams, whose filter tests exactly this field.
      {:ok, status} =
        Statuses.create_status(
          %{"account_id" => account.id, "text" => "watch this", "visibility" => "public"},
          media_ids: [two.id, one.id]
        )

      assert status.ordered_media_attachment_ids == [two.id, one.id]
    end

    test "refuses a post that is both a poll and pictures", %{conn: conn, account: account} do
      attachment = attachment_fixture(account)

      assert json_response(
               post(conn, "/api/v1/statuses", %{
                 "status" => "both",
                 "media_ids" => [to_string(attachment.id)],
                 "poll" => %{"options" => ["a", "b"], "expires_in" => "3600"}
               }),
               422
             )["error"]
    end
  end

  describe "scheduling from the compose endpoint" do
    test "a scheduled_at makes a plan rather than a post", %{conn: conn} do
      # The same endpoint answers both, because that is how every client sends
      # it, and the two answers are different shapes.
      at = DateTime.add(DateTime.utc_now(), 3600, :second)

      body =
        conn
        |> post("/api/v1/statuses", %{
          "text" => "later",
          "scheduled_at" => DateTime.to_iso8601(at)
        })
        |> json_response(200)

      assert body["scheduled_at"]
      assert body["params"]["text"] == "later"
      refute Map.has_key?(body, "content")
      assert Repo.aggregate(Status, :count) == 0
    end

    test "stores the text under one name, not both", %{conn: conn} do
      at = DateTime.add(DateTime.utc_now(), 3600, :second)

      body =
        conn
        |> post("/api/v1/statuses", %{
          "status" => "later",
          "scheduled_at" => DateTime.to_iso8601(at)
        })
        |> json_response(200)

      # What is stored here is replayed when the post goes out and handed back
      # to clients meanwhile, so the wire spelling must not survive into it.
      assert body["params"]["text"] == "later"
      refute Map.has_key?(body["params"], "status")
    end

    test "refuses a scheduled post naming somebody else's upload", %{conn: conn} do
      theirs = attachment_fixture(account_fixture())
      at = DateTime.add(DateTime.utc_now(), 3600, :second)

      # Scheduling checked nothing, so it was a way round every check the
      # immediate path makes — and the answer rendered the stranger's alt
      # text, filename and URL straight back.
      assert json_response(
               post(conn, "/api/v1/statuses", %{
                 "status" => "later",
                 "media_ids" => [to_string(theirs.id)],
                 "scheduled_at" => DateTime.to_iso8601(at)
               }),
               422
             )["error"]

      assert Repo.aggregate(ScheduledStatus, :count) == 0
    end

    test "renders only the scheduler's own uploads, whatever the row names", %{
      account: account
    } do
      theirs = attachment_fixture(account_fixture())
      mine = attachment_fixture(account)

      # Written straight to the row rather than through the endpoint, because
      # the endpoint now refuses this. The renderer is the second lock: an id
      # is timestamped and therefore guessable, and rendering one back would
      # hand over a stranger's alt text, filename and URL.
      scheduled =
        Repo.insert!(%ScheduledStatus{
          account_id: account.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          params: %{"text" => "later"},
          media_attachment_ids: [theirs.id, mine.id]
        })

      rendered = Entities.scheduled_status(scheduled)

      assert [%{"id" => id}] = rendered["media_attachments"]
      assert id == to_string(mine.id)
    end

    test "a scheduled post keeps its pictures until it goes out", %{
      conn: conn,
      account: account
    } do
      attachment = attachment_fixture(account)
      at = DateTime.add(DateTime.utc_now(), 3600, :second)

      body =
        conn
        |> post("/api/v1/statuses", %{
          "status" => "later, with a picture",
          "media_ids" => [to_string(attachment.id)],
          "scheduled_at" => DateTime.to_iso8601(at)
        })
        |> json_response(200)

      assert [%{"id" => id}] = body["media_attachments"]
      assert id == to_string(attachment.id)

      scheduled = Repo.get!(ScheduledStatus, String.to_integer(body["id"]))
      {:ok, status} = Statuses.publish_scheduled(scheduled)

      # The row carried the ids all along; publishing was throwing them away,
      # so a post written with a picture went out without one.
      assert Repo.reload!(attachment).status_id == status.id
      assert status.ordered_media_attachment_ids == [attachment.id]
    end

    test "a time too close is refused", %{conn: conn} do
      soon = DateTime.add(DateTime.utc_now(), 60, :second)

      conn =
        post(conn, "/api/v1/statuses", %{
          "text" => "soon",
          "scheduled_at" => DateTime.to_iso8601(soon)
        })

      assert json_response(conn, 422)["error"] =~ "Validation failed"
    end

    test "a scheduled_at that is not a time is refused", %{conn: conn} do
      conn = post(conn, "/api/v1/statuses", %{"text" => "x", "scheduled_at" => "whenever"})

      assert json_response(conn, 422)["error"] =~ "invalid"
    end
  end

  describe "what may be scheduled at all" do
    setup do
      %{at: DateTime.utc_now() |> DateTime.add(2, :hour) |> DateTime.to_iso8601()}
    end

    test "a post too long to publish is refused now, not dropped at three in the morning", %{
      conn: conn,
      at: at
    } do
      # Scheduling checked only the queue limits, and publication runs the
      # full changeset -- so a post the changeset would refuse scheduled
      # cleanly and was then silently dropped by the worker while its author
      # slept, with a server log line nobody sees as the only trace. The
      # refusal has to come while the person is still looking at the compose
      # box, which is what the reference implementation does too.
      body =
        conn
        |> post("/api/v1/statuses", %{
          "status" => String.duplicate("a", 600),
          "scheduled_at" => at
        })
        |> json_response(422)

      assert body["error"] =~ "Validation failed"
      assert Repo.aggregate(ScheduledStatus, :count) == 0, "the doomed post was scheduled anyway"
    end

    test "and so is a poll whose option cannot be stored", %{conn: conn, at: at} do
      # The option-count checks already ran at the API; the per-option length
      # only failed at publication, the same silent drop.
      body =
        conn
        |> post("/api/v1/statuses", %{
          "status" => "pick one",
          "poll" => %{
            "options" => ["fine", String.duplicate("x", 60)],
            "expires_in" => "3600"
          },
          "scheduled_at" => at
        })
        |> json_response(422)

      assert body["error"] =~ "Validation failed"
      assert Repo.aggregate(ScheduledStatus, :count) == 0
    end

    test "while a publishable post still schedules", %{conn: conn, at: at} do
      # The control: eager validation must not refuse what publication would
      # accept.
      body =
        conn
        |> post("/api/v1/statuses", %{
          "status" => "see you at three",
          "poll" => %{"options" => ["tea", "coffee"], "expires_in" => "3600"},
          "scheduled_at" => at
        })
        |> json_response(200)

      assert body["scheduled_at"]
      assert Repo.aggregate(ScheduledStatus, :count) == 1
    end
  end

  describe "translating" do
    test "says plainly that this server does not", %{conn: conn, account: account} do
      # A client asking gets told, rather than getting a 404 it would read as
      # the post not existing.
      status = status_fixture(%{account_id: account.id})

      conn = post(conn, "/api/v1/statuses/#{status.id}/translate")

      assert json_response(conn, 501)["error"] =~ "not enabled"
    end
  end

  describe "reading" do
    setup %{account: account} do
      %{status: status_fixture(%{account_id: account.id, text: "hello"})}
    end

    test "one post", %{conn: conn, status: status} do
      assert json_response(get(conn, "/api/v1/statuses/#{status.id}"), 200)["content"] ==
               "<p>hello</p>"
    end

    test "a post that is not there", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/statuses/999999"), 404)["error"]
    end

    test "an id that is not an id", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/statuses/nonsense"), 404)["error"]
    end

    test "several at once, for filling gaps in a timeline", %{
      conn: conn,
      status: status,
      account: account
    } do
      other = status_fixture(%{account_id: account.id, text: "second"})

      conn = get(conn, "/api/v1/statuses", %{"id" => [to_string(status.id), to_string(other.id)]})

      assert length(json_response(conn, 200)) == 2
    end

    test "the source, for an edit box", %{conn: conn, status: status} do
      assert json_response(get(conn, "/api/v1/statuses/#{status.id}/source"), 200)["text"] ==
               "hello"
    end

    test "not somebody else's source", %{status: status, application: application} do
      # The source is what an author typed. Nobody else is editing it.
      stranger = token_for(application, account_fixture())

      assert json_response(get(stranger, "/api/v1/statuses/#{status.id}/source"), 403)["error"]
    end

    test "the thread around it", %{conn: conn, status: status, account: account} do
      reply = status_fixture(%{account_id: account.id, in_reply_to_id: status.id})

      body = json_response(get(conn, "/api/v1/statuses/#{status.id}/context"), 200)

      assert body["ancestors"] == []
      assert [%{"id" => id}] = body["descendants"]
      assert id == to_string(reply.id)
    end

    test "a private post is not readable by a stranger", %{
      account: account,
      application: application
    } do
      private = status_fixture(%{account_id: account.id, visibility: :private})
      stranger = token_for(application, account_fixture())

      assert json_response(get(stranger, "/api/v1/statuses/#{private.id}"), 404)["error"]
    end

    test "nor is a public one, once its author has blocked them", %{
      account: account,
      status: status,
      application: application
    } do
      blocked = account_fixture()
      {:ok, _} = Relationships.block(account, blocked)
      conn = token_for(application, blocked)

      assert json_response(get(conn, "/api/v1/statuses/#{status.id}"), 404)["error"]

      for path <- ~w(context history reblogged_by favourited_by quotes) do
        assert json_response(get(conn, "/api/v1/statuses/#{status.id}/#{path}"), 404)["error"],
               "#{path} is a way of reading the same post"
      end

      assert json_response(post(conn, "/api/v1/statuses/#{status.id}/translate"), 404)["error"],
             "and so is asking for it in another language"
    end

    test "and neither does putting a mark on it", %{
      account: account,
      status: status,
      application: application
    } do
      # Being shown the post is what these do, so they come through the same
      # door. The reference implementation refuses all five in the same place.
      blocked = account_fixture()
      {:ok, _} = Relationships.block(account, blocked)
      conn = token_for(application, blocked)

      for action <- ~w(favourite bookmark reblog mute pin) do
        assert json_response(post(conn, "/api/v1/statuses/#{status.id}/#{action}"), 404)["error"],
               "#{action} handed back the body of a post its author refused them"
      end
    end

    test "a reader's own block does not close the link they followed", %{
      status: status,
      account: account,
      application: application
    } do
      # The other direction, and deliberately not symmetrical: "the one place
      # you still see them is their own profile, if you go and look".
      reader = account_fixture()
      {:ok, _} = Relationships.block(reader, account)
      conn = token_for(application, reader)

      assert json_response(get(conn, "/api/v1/statuses/#{status.id}"), 200)["content"]
    end

    test "and the batch drops it rather than answering it", %{
      account: account,
      status: status,
      application: application
    } do
      blocked = account_fixture()
      mine = status_fixture(%{account_id: blocked.id})
      {:ok, _} = Relationships.block(account, blocked)
      conn = token_for(application, blocked)

      body =
        json_response(
          get(conn, "/api/v1/statuses", %{"id" => [to_string(status.id), to_string(mine.id)]}),
          200
        )

      assert Enum.map(body, & &1["id"]) == [to_string(mine.id)]
    end
  end

  describe "editing and deleting" do
    setup %{account: account} do
      %{status: status_fixture(%{account_id: account.id, text: "before"})}
    end

    test "an edit changes the text", %{conn: conn, status: status} do
      conn = put(conn, "/api/v1/statuses/#{status.id}", %{"text" => "after"})

      assert json_response(conn, 200)["content"] == "<p>after</p>"
    end

    test "an edit takes status too, the same as posting does", %{conn: conn, status: status} do
      conn = put(conn, "/api/v1/statuses/#{status.id}", %{"status" => "after"})

      assert json_response(conn, 200)["content"] == "<p>after</p>"
    end

    test "only the author may edit", %{status: status, application: application} do
      stranger = token_for(application, account_fixture())

      conn = put(stranger, "/api/v1/statuses/#{status.id}", %{"text" => "mine now"})

      assert json_response(conn, 403)["error"]
    end

    test "deleting hands the text back for a redraft", %{conn: conn, status: status} do
      # Every client's button is "delete and redraft" and puts the text
      # straight back in the compose box. A 204 would lose it.
      body = json_response(delete(conn, "/api/v1/statuses/#{status.id}"), 200)

      assert body["text"] == "before"
      refute Statuses.get_status(status.id, nil)
    end

    test "only the author may delete", %{status: status, application: application} do
      stranger = token_for(application, account_fixture())

      assert json_response(delete(stranger, "/api/v1/statuses/#{status.id}"), 403)["error"]
    end

    test "the history lists what it used to say, and what it says now", %{
      conn: conn,
      status: status
    } do
      # The list used to stop one version short: each stored row is the state
      # *before* an edit, so the newest text -- the one somebody opened the
      # history to see -- was the one version missing from it.
      {:ok, status} = Statuses.edit_status(status, %{"text" => "after"})
      {:ok, _} = Statuses.edit_status(status, %{"text" => "after all"})

      assert [first, second, third] =
               json_response(get(conn, "/api/v1/statuses/#{status.id}/history"), 200)

      assert first["content"] == "<p>before</p>"
      assert second["content"] == "<p>after</p>"
      assert third["content"] == "<p>after all</p>"
    end

    test "and renders each version rather than handing back raw text", %{
      conn: conn,
      status: status
    } do
      # A client puts these straight into the page beside the current version.
      # Unrendered text shows markup a local author never typed and kills every
      # link in it.
      {:ok, _} =
        Statuses.edit_status(status, %{"text" => "see https://example.com/page"})

      assert [_before, latest] =
               json_response(get(conn, "/api/v1/statuses/#{status.id}/history"), 200)

      assert latest["content"] =~ ~s|<a href="https://example.com/page"|
    end

    test "an edit can fix the alt text on a picture already posted", %{
      conn: conn,
      status: status
    } do
      # `Media.update_upload/2` refuses once a picture is on a post, and its
      # own note says the post is the place to change it. Nothing read
      # `media_attributes`, so there was no such place: a typo in alt text
      # could not be fixed after posting, which is a correction somebody makes
      # for a reader who cannot see the picture.
      {:ok, attachment} =
        Media.create_attachment(%{
          account_id: status.account_id,
          status_id: status.id,
          type: :image,
          processing: :complete,
          file_file_name: "photo.png",
          file_content_type: "image/png",
          file_file_size: 4,
          description: "a typo"
        })

      body =
        json_response(
          put(conn, "/api/v1/statuses/#{status.id}", %{
            "status" => "before",
            "media_attributes" => [
              %{"id" => to_string(attachment.id), "description" => "a red rectangle"}
            ]
          }),
          200
        )

      assert [%{"description" => "a red rectangle"}] = body["media_attachments"]
      assert Repo.reload!(attachment).description == "a red rectangle"
    end

    test "and somebody else's picture is left alone", %{conn: conn, status: status} do
      # The control. A stale or borrowed id is skipped rather than refused, so
      # the edit still happens -- but it must not reach a picture on another
      # post.
      stranger = account_fixture()
      theirs = status_fixture(%{account_id: stranger.id, text: "theirs"})

      {:ok, attachment} =
        Media.create_attachment(%{
          account_id: stranger.id,
          status_id: theirs.id,
          type: :image,
          processing: :complete,
          file_file_name: "photo.png",
          file_content_type: "image/png",
          file_file_size: 4,
          description: "not yours to change"
        })

      json_response(
        put(conn, "/api/v1/statuses/#{status.id}", %{
          "status" => "before",
          "media_attributes" => [
            %{"id" => to_string(attachment.id), "description" => "changed"}
          ]
        }),
        200
      )

      assert Repo.reload!(attachment).description == "not yours to change"
    end

    test "and a post nobody edited answers with itself", %{conn: conn, status: status} do
      # Upstream answers with one synthesised version rather than nothing, so a
      # client never shows an empty history for a post it can see.
      assert [only] = json_response(get(conn, "/api/v1/statuses/#{status.id}/history"), 200)

      assert only["content"] == "<p>before</p>"
    end
  end

  describe "interacting" do
    setup %{application: application} do
      author = account_fixture()

      %{
        status: status_fixture(%{account_id: author.id, text: "theirs"}),
        author: author,
        application: application
      }
    end

    test "deleting has a budget of its own", %{conn: conn, account: account} do
      # Thirty in half an hour, counted against the account. The general API
      # budget is 1,500 in five minutes, so without a bucket of its own a
      # script could empty an account's whole history in a couple of minutes.
      mine = for _ <- 1..40, do: status_fixture(%{account_id: account.id, text: "mine"})

      results = for status <- mine, do: delete(conn, "/api/v1/statuses/#{status.id}").status

      assert 429 in results

      # The positive control: the first ones went through, so the 429 is the
      # budget running out rather than deleting being broken.
      assert 200 in results
    end

    test "undoing a boost counts against the same budget", %{conn: conn, status: status} do
      # A boost and its undo are how a post is removed from other people's
      # timelines, so they belong in the deletion budget rather than the
      # general one.
      results =
        for _ <- 1..40 do
          post(conn, "/api/v1/statuses/#{status.id}/reblog")
          post(conn, "/api/v1/statuses/#{status.id}/unreblog").status
        end

      assert 429 in results
      assert 200 in results
    end

    test "favouriting is not in it", %{conn: conn, status: status} do
      # The narrower bucket must not quietly bound everything next to it. Both
      # halves are collected: reading only the undo would leave a bucket that
      # wrongly covered `favourite` invisible, which is the exact mistake this
      # test is named after.
      results =
        for _ <- 1..40 do
          [
            post(conn, "/api/v1/statuses/#{status.id}/favourite").status,
            post(conn, "/api/v1/statuses/#{status.id}/unfavourite").status
          ]
        end

      results = List.flatten(results)

      refute 429 in results
      assert 200 in results
    end

    test "favouriting and taking it back", %{conn: conn, status: status} do
      assert json_response(post(conn, "/api/v1/statuses/#{status.id}/favourite"), 200)[
               "favourited"
             ]

      refute json_response(post(conn, "/api/v1/statuses/#{status.id}/unfavourite"), 200)[
               "favourited"
             ]
    end

    test "boosting and taking it back", %{conn: conn, status: status} do
      assert json_response(post(conn, "/api/v1/statuses/#{status.id}/reblog"), 200)["reblogged"]
      refute json_response(post(conn, "/api/v1/statuses/#{status.id}/unreblog"), 200)["reblogged"]
    end

    test "bookmarking and taking it back", %{conn: conn, status: status} do
      assert json_response(post(conn, "/api/v1/statuses/#{status.id}/bookmark"), 200)[
               "bookmarked"
             ]

      refute json_response(post(conn, "/api/v1/statuses/#{status.id}/unbookmark"), 200)[
               "bookmarked"
             ]
    end

    test "muting a thread and taking it back", %{conn: conn, author: author} do
      conversation = conversation_fixture()
      status = status_fixture(%{account_id: author.id, conversation_id: conversation.id})

      assert json_response(post(conn, "/api/v1/statuses/#{status.id}/mute"), 200)["muted"]
      refute json_response(post(conn, "/api/v1/statuses/#{status.id}/unmute"), 200)["muted"]
    end

    test "and the mark still comes off a post whose author has since blocked them", %{
      conn: conn,
      status: status,
      account: account,
      author: author
    } do
      # `/bookmarks` lists what somebody saved whatever has happened since, so
      # taking a mark back reads through `Statuses.actionable/2` rather than
      # `readable/2`. A sweep moving it would leave the button in every client
      # doing nothing, with a green suite.
      assert json_response(post(conn, "/api/v1/statuses/#{status.id}/bookmark"), 200)[
               "bookmarked"
             ]

      {:ok, _} = Relationships.block(author, account)

      assert Enum.any?(Statuses.bookmarks(account), &(&1.status.id == status.id))

      refute json_response(post(conn, "/api/v1/statuses/#{status.id}/unbookmark"), 200)[
               "bookmarked"
             ]

      assert json_response(get(conn, "/api/v1/statuses/#{status.id}"), 404)["error"],
             "reading it is still refused"
    end

    test "every un-action is a POST, because that is what clients send", %{
      conn: conn,
      status: status
    } do
      # A DELETE-only endpoint would leave the button in an app doing nothing.
      for action <- ~w(unfavourite unreblog unbookmark unpin) do
        conn = post(conn, "/api/v1/statuses/#{status.id}/#{action}")

        assert conn.status == 200
      end
    end

    test "boosting somebody else's followers-only post is refused", %{conn: conn} do
      # Being allowed to read it is not the same permission as being allowed
      # to carry it to your own followers.
      author = account_fixture()
      private = status_fixture(%{account_id: author.id, visibility: :private})

      conn = post(conn, "/api/v1/statuses/#{private.id}/reblog")

      assert conn.status in [404, 422]
    end

    test "pinning is only for your own public posts", %{conn: conn, status: status} do
      assert json_response(post(conn, "/api/v1/statuses/#{status.id}/pin"), 422)["error"]
    end

    test "pinning your own", %{conn: conn, account: account} do
      own = status_fixture(%{account_id: account.id})

      assert json_response(post(conn, "/api/v1/statuses/#{own.id}/pin"), 200)["pinned"]
      refute json_response(post(conn, "/api/v1/statuses/#{own.id}/unpin"), 200)["pinned"]
    end

    test "who boosted and who favourited", %{conn: conn, status: status, account: account} do
      {:ok, _} = Statuses.boost(account, status)
      {:ok, _} = Statuses.favourite(account, status)

      assert [%{"id" => id}] =
               json_response(get(conn, "/api/v1/statuses/#{status.id}/reblogged_by"), 200)

      assert id == to_string(account.id)

      assert [%{"id" => ^id}] =
               json_response(get(conn, "/api/v1/statuses/#{status.id}/favourited_by"), 200)
    end
  end

  describe "polls" do
    setup %{account: account} do
      author = account_fixture()
      status = status_fixture(%{account_id: author.id})
      {:ok, poll} = Statuses.create_poll(status, %{options: ["yes", "no"]})

      %{poll: poll, author: author, voter: account}
    end

    test "reading one", %{conn: conn, poll: poll} do
      body = json_response(get(conn, "/api/v1/polls/#{poll.id}"), 200)

      assert body["options"] == [
               %{"title" => "yes", "votes_count" => 0},
               %{"title" => "no", "votes_count" => 0}
             ]
    end

    test "voting in one", %{conn: conn, poll: poll} do
      body =
        json_response(post(conn, "/api/v1/polls/#{poll.id}/votes", %{"choices" => ["0"]}), 200)

      assert body["own_votes"] == [0]
      assert body["voters_count"] == 1
    end

    test "neither, once the author has blocked the reader", %{
      conn: conn,
      poll: poll,
      author: author,
      voter: voter
    } do
      # The poll is reachable exactly when its status is, and the status is now
      # not: a block reaches the poll form the same way it reaches the words.
      {:ok, _} = Relationships.block(author, voter)

      assert json_response(get(conn, "/api/v1/polls/#{poll.id}"), 404)["error"]

      assert json_response(
               post(conn, "/api/v1/polls/#{poll.id}/votes", %{"choices" => ["0"]}),
               404
             )["error"]
    end

    test "voting twice is refused with a message a client can show", %{conn: conn, poll: poll} do
      post(conn, "/api/v1/polls/#{poll.id}/votes", %{"choices" => ["0"]})

      conn = post(conn, "/api/v1/polls/#{poll.id}/votes", %{"choices" => ["1"]})

      assert json_response(conn, 422)["error"] =~ "already voted"
    end

    test "an option that does not exist is refused", %{conn: conn, poll: poll} do
      conn = post(conn, "/api/v1/polls/#{poll.id}/votes", %{"choices" => ["9"]})

      assert json_response(conn, 422)["error"]
    end

    test "a poll on a post the reader may not see is not there", %{
      account: account,
      application: application
    } do
      private = status_fixture(%{account_id: account.id, visibility: :private})
      {:ok, poll} = Statuses.create_poll(private, %{options: ["a", "b"]})
      stranger = token_for(application, account_fixture())

      assert json_response(get(stranger, "/api/v1/polls/#{poll.id}"), 404)["error"]
    end
  end

  describe "scheduled posts" do
    setup %{account: account} do
      at = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, scheduled} = Statuses.schedule(account, %{"text" => "later"}, at)

      %{scheduled: scheduled, at: at}
    end

    test "listing your own", %{conn: conn, scheduled: scheduled} do
      assert [%{"id" => id}] = json_response(get(conn, "/api/v1/scheduled_statuses"), 200)
      assert id == to_string(scheduled.id)
    end

    test "listing nobody else's", %{application: application} do
      stranger = token_for(application, account_fixture())

      assert json_response(get(stranger, "/api/v1/scheduled_statuses"), 200) == []
    end

    test "reading one", %{conn: conn, scheduled: scheduled} do
      body = json_response(get(conn, "/api/v1/scheduled_statuses/#{scheduled.id}"), 200)

      assert body["params"]["text"] == "later"
    end

    test "somebody else's is simply not there", %{scheduled: scheduled, application: application} do
      stranger = token_for(application, account_fixture())

      assert json_response(get(stranger, "/api/v1/scheduled_statuses/#{scheduled.id}"), 404)[
               "error"
             ]
    end

    test "moving one", %{conn: conn, scheduled: scheduled} do
      later = DateTime.add(DateTime.utc_now(), 7200, :second)

      conn =
        put(conn, "/api/v1/scheduled_statuses/#{scheduled.id}", %{
          "scheduled_at" => DateTime.to_iso8601(later)
        })

      assert json_response(conn, 200)["scheduled_at"]
    end

    test "moving one too close is refused", %{conn: conn, scheduled: scheduled} do
      soon = DateTime.add(DateTime.utc_now(), 60, :second)

      conn =
        put(conn, "/api/v1/scheduled_statuses/#{scheduled.id}", %{
          "scheduled_at" => DateTime.to_iso8601(soon)
        })

      assert json_response(conn, 422)["error"] =~ "minutes from now"
    end

    test "cancelling one", %{conn: conn, scheduled: scheduled, account: account} do
      assert json_response(delete(conn, "/api/v1/scheduled_statuses/#{scheduled.id}"), 200) == %{}
      assert Statuses.scheduled(account) == []
    end
  end
end
