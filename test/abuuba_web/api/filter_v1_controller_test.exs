defmodule AbuubaWeb.API.FilterV1ControllerTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Filters
  alias Abuuba.OAuth

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

  describe "the v1 entity" do
    test "is one keyword, wearing its filter's clothes", %{conn: conn} do
      created =
        json_response(
          post(conn, "/api/v1/filters", %{
            "phrase" => "election",
            "context" => ["home", "public"],
            "irreversible" => "true",
            "whole_word" => "true"
          }),
          200
        )

      assert created["phrase"] == "election"
      assert created["context"] == ["home", "public"]
      assert created["irreversible"] == true
      assert created["whole_word"] == true
      assert created["expires_at"] == nil
      assert is_binary(created["id"])

      # The id names the keyword, not the filter. Everything a v1 client then
      # does with that id has to find the keyword again.
      assert json_response(get(conn, "/api/v1/filters/#{created["id"]}"), 200) == created
    end

    test "makes a v2 filter underneath, titled after the phrase", %{conn: conn, account: account} do
      json_response(
        post(conn, "/api/v1/filters", %{"phrase" => "election", "context" => ["home"]}),
        200
      )

      assert [%{title: "election", context: ["home"], filter_action: "warn"} = filter] =
               Filters.all(account)

      assert [%{keyword: "election"}] = filter.keywords
    end

    test "reads back what v2 wrote", %{conn: conn, account: account} do
      {:ok, _filter} =
        Filters.create(account, %{
          "title" => "Sport",
          "context" => ["home"],
          "filter_action" => "hide",
          "keywords_attributes" => [
            %{"keyword" => "football", "whole_word" => true},
            %{"keyword" => "rugby", "whole_word" => false}
          ]
        })

      # One v1 filter per keyword: a v1 client has no way to say "one rule,
      # two spellings", so it is shown two rules.
      assert [one, two] =
               conn
               |> get("/api/v1/filters")
               |> json_response(200)
               |> Enum.sort_by(& &1["phrase"])

      assert one["phrase"] == "football"
      assert one["whole_word"] == true
      assert two["phrase"] == "rugby"
      assert two["whole_word"] == false

      for entity <- [one, two] do
        assert entity["irreversible"] == true
        assert entity["context"] == ["home"]
      end
    end
  end

  describe "expiry" do
    test "expires_in is seconds from now", %{conn: conn} do
      created =
        json_response(
          post(conn, "/api/v1/filters", %{
            "phrase" => "cup final",
            "context" => ["home"],
            "expires_in" => "3600"
          }),
          200
        )

      {:ok, expires_at, _offset} = DateTime.from_iso8601(created["expires_at"])
      seconds = DateTime.diff(expires_at, DateTime.utc_now())

      assert seconds > 3500 and seconds <= 3600
    end

    test "an empty expires_in takes an expiry back off", %{conn: conn} do
      created =
        json_response(
          post(conn, "/api/v1/filters", %{
            "phrase" => "cup final",
            "context" => ["home"],
            "expires_in" => "3600"
          }),
          200
        )

      updated =
        json_response(
          put(conn, "/api/v1/filters/#{created["id"]}", %{
            "phrase" => "cup final",
            "context" => ["home"],
            "expires_in" => ""
          }),
          200
        )

      assert updated["expires_at"] == nil
    end
  end

  describe "changing one" do
    test "renames the keyword and the filter together", %{conn: conn, account: account} do
      created =
        json_response(
          post(conn, "/api/v1/filters", %{"phrase" => "election", "context" => ["home"]}),
          200
        )

      updated =
        json_response(
          put(conn, "/api/v1/filters/#{created["id"]}", %{
            "phrase" => "referendum",
            "context" => ["home", "thread"],
            "irreversible" => "true"
          }),
          200
        )

      assert updated["phrase"] == "referendum"
      assert updated["context"] == ["home", "thread"]
      assert updated["irreversible"] == true

      assert [%{title: "referendum", keywords: [%{keyword: "referendum"}]}] = Filters.all(account)
    end

    test "refuses to reshape a filter that has more than one spelling", %{
      conn: conn,
      account: account
    } do
      # The v1 shape cannot express "one rule, two spellings", so a v1 client
      # editing the rule's context would be editing something it cannot see.
      {:ok, filter} =
        Filters.create(account, %{
          "title" => "Sport",
          "context" => ["home"],
          "keywords_attributes" => [%{"keyword" => "football"}, %{"keyword" => "rugby"}]
        })

      [keyword | _] = filter.keywords

      body =
        json_response(
          put(conn, "/api/v1/filters/#{keyword.id}", %{
            "phrase" => "football",
            "context" => ["public"]
          }),
          422
        )

      assert body["error"] =~ "more than one filter keyword"
      assert [%{context: ["home"]}] = Filters.all(account)
    end

    test "lets a client resend the values it was given, on any number of spellings", %{
      conn: conn,
      account: account
    } do
      # The refusal is about changing the rule, not about mentioning it. A
      # client that echoes back the whole form it was handed has asked for what
      # is already true, and answering that with an error would leave it unable
      # to edit the one field it may.
      {:ok, filter} =
        Filters.create(account, %{
          "title" => "football",
          "context" => ["home"],
          "keywords_attributes" => [%{"keyword" => "football"}, %{"keyword" => "rugby"}]
        })

      keyword = Enum.find(filter.keywords, &(&1.keyword == "football"))

      updated =
        json_response(
          put(conn, "/api/v1/filters/#{keyword.id}", %{
            "phrase" => "football",
            "context" => ["home"],
            "irreversible" => "false",
            "expires_in" => "",
            "whole_word" => "false"
          }),
          200
        )

      assert updated["whole_word"] == false
      assert [%{title: "football", context: ["home"]}] = Filters.all(account)
    end

    test "a rule the write cannot accept leaves nothing behind", %{conn: conn, account: account} do
      # Both halves or neither: a bad context must not leave the keyword
      # renamed under a rule that still says what it said.
      created =
        json_response(
          post(conn, "/api/v1/filters", %{"phrase" => "election", "context" => ["home"]}),
          200
        )

      assert json_response(
               put(conn, "/api/v1/filters/#{created["id"]}", %{
                 "phrase" => "referendum",
                 "context" => ["nowhere"]
               }),
               422
             )

      assert [%{title: "election", keywords: [%{keyword: "election"}]}] = Filters.all(account)
    end

    test "reads a checkbox the way the reference implementation reads one", %{conn: conn} do
      # `on` is what a browser checkbox sends, and it means yes everywhere the
      # reference implementation is deployed. Reading it as no would silently
      # store the opposite of what somebody ticked.
      created =
        json_response(
          post(conn, "/api/v1/filters", %{
            "phrase" => "election",
            "context" => ["home"],
            "whole_word" => "on",
            "irreversible" => "on"
          }),
          200
        )

      assert created["whole_word"] == true
      assert created["irreversible"] == true

      updated =
        json_response(
          patch(conn, "/api/v1/filters/#{created["id"]}", %{"whole_word" => "off"}),
          200
        )

      assert updated["whole_word"] == false
    end

    test "takes a phrase as long as the reference implementation allows", %{conn: conn} do
      phrase = String.duplicate("x", 256)

      created =
        json_response(
          post(conn, "/api/v1/filters", %{"phrase" => phrase, "context" => ["home"]}),
          200
        )

      assert created["phrase"] == phrase
    end

    test "does not fall over on an expiry past the end of time", %{conn: conn} do
      created =
        json_response(
          post(conn, "/api/v1/filters", %{
            "phrase" => "forever",
            "context" => ["home"],
            "expires_in" => "99999999999999"
          }),
          200
        )

      assert {:ok, _expires_at, _offset} = DateTime.from_iso8601(created["expires_at"])
    end

    test "leaves whole_word alone as the one thing v1 may still change", %{
      conn: conn,
      account: account
    } do
      # `phrase` names the rule as well as the spelling in this API, so even a
      # rename is refused on a rule with several. `whole_word` belongs to the
      # spelling alone, so it goes through. The reference implementation draws
      # the line in exactly this place.
      {:ok, filter} =
        Filters.create(account, %{
          "title" => "Sport",
          "context" => ["home"],
          "keywords_attributes" => [
            %{"keyword" => "football", "whole_word" => false},
            %{"keyword" => "rugby"}
          ]
        })

      keyword = Enum.find(filter.keywords, &(&1.keyword == "football"))

      assert json_response(
               put(conn, "/api/v1/filters/#{keyword.id}", %{"phrase" => "soccer"}),
               422
             )

      updated =
        json_response(
          put(conn, "/api/v1/filters/#{keyword.id}", %{"whole_word" => "true"}),
          200
        )

      assert updated["whole_word"] == true
      assert updated["phrase"] == "football"
      assert [%{title: "Sport", keywords: keywords}] = Filters.all(account)
      assert Enum.sort(Enum.map(keywords, & &1.keyword)) == ["football", "rugby"]
    end
  end

  describe "deleting one" do
    test "removes the spelling, leaving the rule behind as the reference does", %{
      conn: conn,
      account: account
    } do
      created =
        json_response(
          post(conn, "/api/v1/filters", %{"phrase" => "election", "context" => ["home"]}),
          200
        )

      assert json_response(delete(conn, "/api/v1/filters/#{created["id"]}"), 200) == %{}
      assert json_response(get(conn, "/api/v1/filters"), 200) == []

      # The rule stays, now matching nothing. That is what the reference
      # implementation does, and a v1 client deleting a spelling has said
      # nothing about the rule.
      assert [%{keywords: []}] = Filters.all(account)
    end

    test "leaves the rule alone when other spellings remain", %{conn: conn, account: account} do
      {:ok, filter} =
        Filters.create(account, %{
          "title" => "Sport",
          "context" => ["home"],
          "keywords_attributes" => [%{"keyword" => "football"}, %{"keyword" => "rugby"}]
        })

      [keyword | _] = filter.keywords

      assert json_response(delete(conn, "/api/v1/filters/#{keyword.id}"), 200) == %{}
      assert [%{title: "Sport", keywords: [_one]}] = Filters.all(account)
    end
  end

  describe "who may see one" do
    test "somebody else's filter is not there", %{conn: conn} do
      {:ok, filter} =
        Filters.create(account_fixture(), %{
          "title" => "Theirs",
          "context" => ["home"],
          "keywords_attributes" => [%{"keyword" => "secret"}]
        })

      [keyword | _] = filter.keywords

      assert json_response(get(conn, "/api/v1/filters"), 200) == []
      assert json_response(get(conn, "/api/v1/filters/#{keyword.id}"), 404)
      assert json_response(delete(conn, "/api/v1/filters/#{keyword.id}"), 404)
      assert [%{keywords: [_still_there]}] = Filters.all(filter.account_id)
    end

    test "a stranger is refused", %{anon: anon} do
      # 422 rather than 401, which is what the reference implementation answers
      # here and therefore what a client's error handling is written against.
      assert %{"error" => _} = json_response(get(anon, "/api/v1/filters"), 422)
    end
  end

  describe "still v2" do
    test "the v2 routes are untouched by any of this", %{conn: conn} do
      # The positive control for the visibility checks above: the same account,
      # the same token, reading its own filters through v2.
      created =
        json_response(
          post(conn, "/api/v2/filters", %{
            "title" => "Sport",
            "context" => ["home"],
            "keywords_attributes" => [%{"keyword" => "football"}]
          }),
          200
        )

      assert created["title"] == "Sport"
      assert [%{"keyword" => "football"}] = created["keywords"]
      assert [%{"id" => id}] = json_response(get(conn, "/api/v2/filters"), 200)
      assert id == created["id"]
    end

    test "catches one post by name, and stops", %{conn: conn, account: account} do
      # A keyword cannot say "that one", which is the post that talks about the
      # thing without ever naming it.
      filter =
        json_response(
          post(conn, "/api/v2/filters", %{
            "title" => "Spoilers",
            "context" => ["home"],
            "keywords_attributes" => [%{"keyword" => "finale"}]
          }),
          200
        )

      status = Abuuba.StatusesFixtures.status_fixture(%{account_id: account_fixture().id})

      added =
        json_response(
          post(conn, "/api/v2/filters/#{filter["id"]}/statuses", %{
            "status_id" => to_string(status.id)
          }),
          200
        )

      assert added["status_id"] == to_string(status.id)
      assert is_binary(added["id"])

      assert [listed] =
               json_response(get(conn, "/api/v2/filters/#{filter["id"]}/statuses"), 200)

      assert listed["id"] == added["id"]
      assert json_response(get(conn, "/api/v2/filters/statuses/#{added["id"]}"), 200) == added

      # The whole point: the named post is filtered even though nothing in it
      # matches the words.
      assert [%{title: "Spoilers"}] = Abuuba.Filters.matching(account, status, "home")

      # And it appears on the filter, so a client editing one can see it.
      assert [%{"status_id" => _}] =
               json_response(get(conn, "/api/v2/filters/#{filter["id"]}"), 200)["statuses"]

      assert json_response(delete(conn, "/api/v2/filters/statuses/#{added["id"]}"), 200) == %{}
      assert Abuuba.Filters.matching(account, status, "home") == []
    end

    test "somebody else's named post is not reachable", %{conn: conn} do
      {:ok, theirs} =
        Filters.create(account_fixture(), %{
          "title" => "Theirs",
          "context" => ["home"],
          "keywords_attributes" => [%{"keyword" => "x"}]
        })

      status = Abuuba.StatusesFixtures.status_fixture(%{account_id: account_fixture().id})
      {:ok, filter_status} = Filters.add_status(theirs, %{"status_id" => status.id})

      assert json_response(get(conn, "/api/v2/filters/statuses/#{filter_status.id}"), 404)
      assert json_response(delete(conn, "/api/v2/filters/statuses/#{filter_status.id}"), 404)
      assert json_response(post(conn, "/api/v2/filters/#{theirs.id}/statuses", %{}), 404)
      assert [_still_there] = Filters.statuses(theirs)
    end

    test "a spelling can be edited on its own", %{conn: conn} do
      filter =
        json_response(
          post(conn, "/api/v2/filters", %{
            "title" => "Sport",
            "context" => ["home"],
            "keywords_attributes" => [%{"keyword" => "football", "whole_word" => "false"}]
          }),
          200
        )

      [%{"id" => id}] = filter["keywords"]

      updated =
        json_response(
          put(conn, "/api/v2/filters/keywords/#{id}", %{
            "keyword" => "soccer",
            "whole_word" => "true"
          }),
          200
        )

      assert updated["keyword"] == "soccer"
      assert updated["whole_word"] == true
    end

    test "v2 takes expires_in too", %{conn: conn} do
      created =
        json_response(
          post(conn, "/api/v2/filters", %{
            "title" => "Sport",
            "context" => ["home"],
            "expires_in" => "1800"
          }),
          200
        )

      assert created["expires_at"] != nil
    end
  end
end
