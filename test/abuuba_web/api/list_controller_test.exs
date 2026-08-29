defmodule AbuubaWeb.API.ListControllerTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Filters
  alias Abuuba.Lists
  alias Abuuba.OAuth
  alias Abuuba.Relationships
  alias Abuuba.Statuses

  setup %{conn: conn} do
    account = account_fixture()

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

  describe "lists" do
    test "create, read, rename, delete", %{conn: conn} do
      created = json_response(post(conn, "/api/v1/lists", %{"title" => "Cycling"}), 200)

      assert created["title"] == "Cycling"
      assert created["replies_policy"] == "list"

      assert [%{"id" => id}] = json_response(get(conn, "/api/v1/lists"), 200)
      assert id == created["id"]

      renamed = json_response(put(conn, "/api/v1/lists/#{id}", %{"title" => "Bikes"}), 200)
      assert renamed["title"] == "Bikes"

      assert json_response(delete(conn, "/api/v1/lists/#{id}"), 200) == %{}
      assert json_response(get(conn, "/api/v1/lists"), 200) == []
    end

    test "somebody else's list is not there", %{conn: conn} do
      {:ok, theirs} = Lists.create(account_fixture(), %{"title" => "Theirs"})

      assert json_response(get(conn, "/api/v1/lists/#{theirs.id}"), 404)["error"]
    end

    test "names the field a validation refused", %{conn: conn} do
      post(conn, "/api/v1/lists", %{"title" => "Cycling"})

      body = json_response(post(conn, "/api/v1/lists", %{"title" => "Cycling"}), 422)

      assert body["details"]["title"]
    end

    test "membership is only people you follow", %{conn: conn, account: account} do
      stranger = account_fixture()
      {:ok, list} = Lists.create(account, %{"title" => "Cycling"})

      conn_refused =
        post(conn, "/api/v1/lists/#{list.id}/accounts", %{
          "account_ids" => [to_string(stranger.id)]
        })

      assert json_response(conn_refused, 422)["error"] =~ "follow them first"

      {:ok, _} = Relationships.follow(account, stranger)

      assert json_response(
               post(conn, "/api/v1/lists/#{list.id}/accounts", %{
                 "account_ids" => [to_string(stranger.id)]
               }),
               200
             )

      assert [%{"id" => id}] = json_response(get(conn, "/api/v1/lists/#{list.id}/accounts"), 200)
      assert id == to_string(stranger.id)
    end

    test "and joins them when the client numbers the ids", %{conn: conn, account: account} do
      # The quietest of this family: `account_ids[0]=x` read as nothing at all,
      # so the answer was 200 and the list stayed empty. Nothing tells the
      # person that the people they added are not in it.
      member = account_fixture()
      {:ok, _} = Relationships.follow(account, member)
      {:ok, list} = Lists.create(account, %{"title" => "Numbered"})

      assert json_response(
               post(conn, "/api/v1/lists/#{list.id}/accounts", %{
                 "account_ids" => %{"0" => to_string(member.id)}
               }),
               200
             )

      assert [%{"id" => id}] = json_response(get(conn, "/api/v1/lists/#{list.id}/accounts"), 200)
      assert id == to_string(member.id)
    end

    test "removing takes them out without unfollowing", %{conn: conn, account: account} do
      member = account_fixture()
      {:ok, _} = Relationships.follow(account, member)
      {:ok, list} = Lists.create(account, %{"title" => "Cycling"})
      :ok = Lists.add(list, [member.id])

      delete(conn, "/api/v1/lists/#{list.id}/accounts", %{"account_ids" => [to_string(member.id)]})

      assert json_response(get(conn, "/api/v1/lists/#{list.id}/accounts"), 200) == []
      assert Relationships.following?(account, member)
    end

    test "the list timeline carries what its members said", %{conn: conn, account: account} do
      member = account_fixture()
      {:ok, _} = Relationships.follow(account, member)
      {:ok, list} = Lists.create(account, %{"title" => "Cycling"})
      :ok = Lists.add(list, [member.id])

      status = status_fixture(%{account_id: member.id, text: "on a bike"})
      status_fixture(%{account_id: account_fixture().id, text: "elsewhere"})

      body = json_response(get(conn, "/api/v1/timelines/list/#{list.id}"), 200)

      assert Enum.map(body, & &1["id"]) == [to_string(status.id)]
    end

    test "a list that does not exist is not an empty timeline", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/timelines/list/999999"), 404)["error"]
    end

    test "an exclusive list takes its members out of home", %{conn: conn, account: account} do
      member = account_fixture()
      {:ok, _} = Relationships.follow(account, member)
      {:ok, list} = Lists.create(account, %{"title" => "Noisy", "exclusive" => true})
      :ok = Lists.add(list, [member.id])

      status_fixture(%{account_id: member.id, text: "noise"})

      assert json_response(get(conn, "/api/v1/timelines/home"), 200) == []
      assert length(json_response(get(conn, "/api/v1/timelines/list/#{list.id}"), 200)) == 1
    end
  end

  describe "filters" do
    test "create with keywords, read back, delete", %{conn: conn} do
      created =
        json_response(
          post(conn, "/api/v2/filters", %{
            "title" => "Elections",
            "context" => ["home"],
            "filter_action" => "hide",
            "keywords_attributes" => [%{"keyword" => "election"}]
          }),
          200
        )

      assert created["filter_action"] == "hide"
      assert [%{"keyword" => "election"}] = created["keywords"]

      assert [_] = json_response(get(conn, "/api/v2/filters"), 200)

      assert json_response(delete(conn, "/api/v2/filters/#{created["id"]}"), 200) == %{}
      assert json_response(get(conn, "/api/v2/filters"), 200) == []
    end

    test "a numbered context names a context", %{conn: conn} do
      # `context[0]=home` answered "must name at least one context" for a
      # request that named one.
      created =
        json_response(
          post(conn, "/api/v2/filters", %{
            "title" => "Numbered",
            "context" => %{"0" => "home", "1" => "public"}
          }),
          200
        )

      assert created["context"] == ["home", "public"]
    end

    test "refuses a filter that applies nowhere", %{conn: conn} do
      conn = post(conn, "/api/v2/filters", %{"title" => "x", "context" => []})

      assert json_response(conn, 422)["details"]["context"]
    end

    test "one spelling can be added and removed on its own", %{conn: conn, account: account} do
      {:ok, filter} =
        Filters.create(account, %{"title" => "Elections", "context" => ["home"]})

      added =
        json_response(
          post(conn, "/api/v2/filters/#{filter.id}/keywords", %{"keyword" => "ballot"}),
          200
        )

      assert added["keyword"] == "ballot"
      assert [_] = json_response(get(conn, "/api/v2/filters/#{filter.id}/keywords"), 200)

      assert json_response(delete(conn, "/api/v1/filters/keywords/#{added["id"]}"), 200) == %{}
      assert json_response(get(conn, "/api/v2/filters/#{filter.id}/keywords"), 200) == []
    end

    test "somebody else's filter is not there", %{conn: conn} do
      {:ok, theirs} =
        Filters.create(account_fixture(), %{"title" => "Theirs", "context" => ["home"]})

      assert json_response(get(conn, "/api/v2/filters/#{theirs.id}"), 404)["error"]
    end
  end

  describe "the kept lists" do
    test "favourites and bookmarks, newest mark first", %{conn: conn, account: account} do
      author = account_fixture()
      older = status_fixture(%{account_id: author.id, text: "older"})
      newer = status_fixture(%{account_id: author.id, text: "newer"})

      {:ok, _} = Statuses.favourite(account, newer)
      {:ok, _} = Statuses.favourite(account, older)
      {:ok, _} = Statuses.bookmark(account, older)

      # Marked in that order, so the one saved last is at the top even though
      # it was written first.
      assert ["<p>older</p>", "<p>newer</p>"] =
               json_response(get(conn, "/api/v1/favourites"), 200) |> Enum.map(& &1["content"])

      assert [%{"content" => "<p>older</p>"}] = json_response(get(conn, "/api/v1/bookmarks"), 200)
    end

    test "are one account's", %{conn: conn} do
      other = account_fixture()
      status = status_fixture(%{account_id: account_fixture().id})
      {:ok, _} = Statuses.favourite(other, status)

      assert json_response(get(conn, "/api/v1/favourites"), 200) == []
    end

    test "page by the mark, so following the Link header actually advances", %{
      conn: conn,
      account: account
    } do
      # The cursor has to be the favourite's id, not the post's: post ids are
      # snowflakes and mark ids are not, so a snowflake cursor matches every
      # mark and the client is handed page one forever.
      author = account_fixture()
      first = status_fixture(%{account_id: author.id, text: "first"})
      second = status_fixture(%{account_id: author.id, text: "second"})
      {:ok, older_mark} = Statuses.favourite(account, first)
      {:ok, newer_mark} = Statuses.favourite(account, second)

      response = get(conn, "/api/v1/favourites?limit=1")
      [link] = get_resp_header(response, "link")

      assert link =~ "max_id=#{newer_mark.id}"
      refute link =~ "max_id=#{second.id}"

      assert [%{"content" => "<p>first</p>"}] =
               json_response(get(conn, "/api/v1/favourites?limit=1&max_id=#{newer_mark.id}"), 200)

      assert json_response(
               get(conn, "/api/v1/favourites?limit=1&max_id=#{older_mark.id}"),
               200
             ) == []
    end

    test "need a token", %{anon: anon} do
      assert json_response(get(anon, "/api/v1/favourites"), 422)["error"]
    end
  end

  describe "conversations" do
    test "show one line per exchange", %{conn: conn, account: account} do
      # Twenty messages back and forth is one conversation somebody is having,
      # not twenty things to read.
      other = account_fixture()
      conversation = conversation_fixture()

      # The handle is in the text, which is how a direct message names who it
      # is for: that is what records the mention and files the inbox row.
      for text <- ["hello", "hi", "how are you"] do
        status_fixture(%{
          account_id: other.id,
          text: "@#{account.username} #{text}",
          visibility: :direct,
          conversation_id: conversation.id
        })
      end

      assert [entry] = json_response(get(conn, "/api/v1/conversations"), 200)
      assert entry["last_status"]["content"] =~ "how are you"
      assert [%{"id" => id}] = entry["accounts"]
      assert id == to_string(other.id)
    end

    test "a note to yourself names you rather than nobody", %{conn: conn, account: account} do
      # A direct post that mentions nobody is a conversation with one person in
      # it. The participant list came back empty, and a client draws that row
      # from `accounts`: an exchange with no name and no avatar, which reads as
      # a broken entry rather than as a note somebody wrote to themselves.
      conversation = conversation_fixture()

      status_fixture(%{
        account_id: account.id,
        text: "reminder to myself",
        visibility: :direct,
        conversation_id: conversation.id
      })

      assert [entry] = json_response(get(conn, "/api/v1/conversations"), 200)
      assert [%{"id" => id}] = entry["accounts"]
      assert id == to_string(account.id)
    end

    test "one can be marked read and unread again", %{conn: conn, account: account} do
      other = account_fixture()
      conversation = conversation_fixture()

      status_fixture(%{
        account_id: other.id,
        text: "@#{account.username} hello",
        visibility: :direct,
        conversation_id: conversation.id
      })

      [entry] = json_response(get(conn, "/api/v1/conversations"), 200)
      assert entry["unread"]

      read = json_response(post(conn, "/api/v1/conversations/#{entry["id"]}/read"), 200)
      refute read["unread"]

      unread = json_response(post(conn, "/api/v1/conversations/#{entry["id"]}/unread"), 200)
      assert unread["unread"]
    end

    test "one can be taken out of an inbox", %{conn: conn, account: account} do
      other = account_fixture()
      conversation = conversation_fixture()

      status_fixture(%{
        account_id: other.id,
        text: "@#{account.username} hello",
        visibility: :direct,
        conversation_id: conversation.id
      })

      [entry] = json_response(get(conn, "/api/v1/conversations"), 200)

      assert json_response(delete(conn, "/api/v1/conversations/#{entry["id"]}"), 200) == %{}
      assert json_response(get(conn, "/api/v1/conversations"), 200) == []
    end

    test "marking one read answers rather than erroring", %{conn: conn} do
      # A client marks a conversation read as soon as somebody opens it, and a
      # 404 would show them an error for having read their own messages.
      assert json_response(post(conn, "/api/v1/conversations/1/read"), 200) == %{}
    end
  end
end
