defmodule AbuubaWeb.API.AccountControllerTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.OAuth
  alias Abuuba.Relationships
  alias Abuuba.Statuses

  setup %{conn: conn} do
    account = account_fixture(%{username: "alice", display_name: "Alice"})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    %{
      conn: authorize(conn, application, account),
      anon: build_conn(),
      account: account,
      application: application
    }
  end

  defp authorize(conn, application, account) do
    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write", "follow"])

    put_req_header(conn, "authorization", "Bearer " <> raw)
  end

  describe "what a client is told about permissions" do
    test "a role travels with verify_credentials", %{conn: conn, account: account} do
      user = Abuuba.Repo.get_by!(Abuuba.Accounts.User, account_id: account.id)

      {:ok, role} =
        Abuuba.Roles.create(%{
          name: "Moderator",
          permissions: Abuuba.Roles.mask(["manage_reports"]),
          position: 10
        })

      {:ok, _} = Abuuba.Roles.assign(user, role)

      body = json_response(get(conn, "/api/v1/accounts/verify_credentials"), 200)

      assert body["role"]["name"] == "Moderator"
      # The decimal string of the bitmask, which is what a client parses.
      assert body["role"]["permissions"] == to_string(Abuuba.Roles.mask(["manage_reports"]))
    end

    test "somebody with no role is sent no role at all", %{conn: conn} do
      body = json_response(get(conn, "/api/v1/accounts/verify_credentials"), 200)

      refute Map.has_key?(body, "role")
    end
  end

  describe "who am I" do
    test "answers with the account and its private source", %{conn: conn} do
      body = json_response(get(conn, "/api/v1/accounts/verify_credentials"), 200)

      assert body["username"] == "alice"
      assert body["source"]["note"] == ""
    end

    test "needs a token", %{anon: anon} do
      assert json_response(get(anon, "/api/v1/accounts/verify_credentials"), 422)["error"]
    end
  end

  describe "changing your own profile" do
    test "updates what you say about yourself", %{conn: conn} do
      conn =
        patch(conn, "/api/v1/accounts/update_credentials", %{
          "display_name" => "Alice A",
          "note" => "hello"
        })

      body = json_response(conn, 200)

      assert body["display_name"] == "Alice A"
      assert body["note"] == "hello"
    end

    test "takes the sites allowed to name you as an author", %{conn: conn, account: account} do
      conn =
        patch(conn, "/api/v1/accounts/update_credentials", %{
          "attribution_domains" => ["https://news.example/", "*.blog.example"]
        })

      assert json_response(conn, 200)["source"]["attribution_domains"] == [
               "news.example",
               "blog.example"
             ]

      assert Accounts.get_account(account.id).attribution_domains == [
               "news.example",
               "blog.example"
             ]
    end

    test "and leaves them alone when the save is about something else", %{
      conn: conn,
      account: account
    } do
      # A profile save that never mentions the list must not empty it, which is
      # what taking an absent parameter as `[]` would do.
      {:ok, _} = Accounts.update_profile(account, %{"attribution_domains" => ["news.example"]})

      patch(conn, "/api/v1/accounts/update_credentials", %{"display_name" => "Alice A"})

      assert Accounts.get_account(account.id).attribution_domains == ["news.example"]
    end

    test "cannot reach past the profile into moderation state", %{conn: conn, account: account} do
      # These parameters came from the account's owner. The trusted changeset
      # would let somebody lift their own suspension.
      patch(conn, "/api/v1/accounts/update_credentials", %{
        "suspended_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "username" => "someone_else"
      })

      reloaded = Accounts.get_account(account.id)

      assert reloaded.username == "alice"
      assert is_nil(reloaded.suspended_at)
    end

    test "sets the profile fields a client numbered", %{conn: conn} do
      # `fields_attributes[0][name]` is the form the API documentation uses,
      # and Phoenix hands it over as a map keyed by the index rather than a
      # list. Nothing covered this at all, which is how it went unnoticed that
      # the index was sorted as a string.
      body =
        conn
        |> patch("/api/v1/accounts/update_credentials", %{
          "fields_attributes" => %{
            "0" => %{"name" => "Web", "value" => "https://example.com"},
            "1" => %{"name" => "Job", "value" => "Dev"}
          }
        })
        |> json_response(200)

      assert Enum.map(body["fields"], & &1["name"]) == ["Web", "Job"]
    end

    test "and refuses rubbish rather than emptying them", %{conn: conn, account: account} do
      # A 200 here would be the worst answer available: the client sent
      # something malformed and somebody's links would be gone.
      {:ok, _} =
        Accounts.update_profile(account, %{
          "fields" => [%{"name" => "Web", "value" => "https://example.com"}]
        })

      body =
        conn
        |> patch("/api/v1/accounts/update_credentials", %{"fields_attributes" => ["hello"]})
        |> json_response(422)

      assert body["details"]["fields"]
      assert [%{name: "Web"}] = Accounts.get_account(account.id).fields
    end

    test "names the field a validation refused", %{conn: conn} do
      # A form has to put the message next to the box somebody typed in.
      conn =
        patch(conn, "/api/v1/accounts/update_credentials", %{
          "display_name" => String.duplicate("a", 100)
        })

      body = json_response(conn, 422)

      assert body["error"] =~ "Validation failed"
      assert body["details"]["display_name"]
    end
  end

  describe "reading somebody" do
    setup do
      %{other: account_fixture(%{username: "bob"})}
    end

    test "by id", %{conn: conn, other: other} do
      assert json_response(get(conn, "/api/v1/accounts/#{other.id}"), 200)["username"] == "bob"
    end

    test "without a token, because a profile is not hidden", %{anon: anon, other: other} do
      assert json_response(get(anon, "/api/v1/accounts/#{other.id}"), 200)["username"] == "bob"
    end

    test "a suspended account is simply not there", %{conn: conn, other: other} do
      {:ok, _} = Accounts.update_moderation(other, %{suspended_at: DateTime.utc_now()})

      assert json_response(get(conn, "/api/v1/accounts/#{other.id}"), 404)["error"]
    end

    test "by the handle somebody typed", %{conn: conn, other: other} do
      body = json_response(get(conn, "/api/v1/accounts/lookup", %{"acct" => "@bob"}), 200)

      assert body["id"] == to_string(other.id)
    end

    test "searching half a name", %{conn: conn, other: other} do
      assert [%{"id" => id}] =
               json_response(get(conn, "/api/v1/accounts/search", %{"q" => "bo"}), 200)

      assert id == to_string(other.id)
    end

    test "narrowing a search to people you follow", %{conn: conn, account: account, other: other} do
      # `following=true` was mapped to "local accounts only", which is neither
      # what it means nor anything a client can use: it kept people the reader
      # does not follow and dropped the remote ones they do. The same parameter
      # on `/api/v2/search` has always meant the right thing, so the two
      # surfaces answered one question two ways.
      _stranger = account_fixture(%{username: "bobbie"})
      {:ok, _} = Relationships.follow(account, other)

      body =
        json_response(
          get(conn, "/api/v1/accounts/search", %{"q" => "bo", "following" => "true"}),
          200
        )

      assert Enum.map(body, & &1["id"]) == [to_string(other.id)]
    end

    test "and keeps the remote people you follow in it", %{
      conn: conn,
      account: account
    } do
      # The half that made it a silent wrong answer rather than a narrow one.
      remote = account_fixture(%{username: "bosun", domain: "remote.example"})
      {:ok, _} = Relationships.follow(account, remote)

      body =
        json_response(
          get(conn, "/api/v1/accounts/search", %{"q" => "bo", "following" => "true"}),
          200
        )

      assert to_string(remote.id) in Enum.map(body, & &1["id"])
    end

    test "and a search that says nothing about following is unchanged", %{
      conn: conn,
      other: other
    } do
      # The positive control: `resolve=false` used to hide every remote account
      # this server already holds, which is not what resolving means.
      remote = account_fixture(%{username: "bosun", domain: "remote.example"})

      ids =
        conn
        |> get("/api/v1/accounts/search", %{"q" => "bo", "resolve" => "false"})
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert to_string(other.id) in ids
      assert to_string(remote.id) in ids
    end

    test "their posts, filtered for the reader", %{conn: conn, other: other} do
      status_fixture(%{account_id: other.id, text: "public"})
      status_fixture(%{account_id: other.id, text: "private", visibility: :private})

      body = json_response(get(conn, "/api/v1/accounts/#{other.id}/statuses"), 200)

      assert Enum.map(body, & &1["content"]) == ["<p>public</p>"]
    end

    test "and the filters an app asks for are applied", %{conn: conn, other: other} do
      # The support was already there and already used -- the profile page
      # passes these and so does the feed -- and this endpoint dropped them,
      # so the web interface was right and every third-party client was wrong.
      # Opening a profile in an app and tapping "Posts" showed replies.
      root = status_fixture(%{account_id: other.id, text: "a post"})
      status_fixture(%{account_id: other.id, text: "a reply", in_reply_to_id: root.id})

      body =
        json_response(
          get(conn, "/api/v1/accounts/#{other.id}/statuses", %{"exclude_replies" => "true"}),
          200
        )

      assert Enum.map(body, & &1["content"]) == ["<p>a post</p>"]
    end

    test "and pinned=true answers with the pinned posts", %{conn: conn, other: other} do
      pinned = status_fixture(%{account_id: other.id, text: "at the top"})
      status_fixture(%{account_id: other.id, text: "newer than the pin"})

      {:ok, _pin} = Statuses.pin(other, pinned)

      body =
        json_response(
          get(conn, "/api/v1/accounts/#{other.id}/statuses", %{"pinned" => "true"}),
          200
        )

      assert Enum.map(body, & &1["content"]) == ["<p>at the top</p>"]
    end

    test "their followers and who they follow", %{conn: conn, other: other, account: account} do
      {:ok, _} = Relationships.follow(account, other)

      assert [%{"id" => id}] =
               json_response(get(conn, "/api/v1/accounts/#{other.id}/followers"), 200)

      assert id == to_string(account.id)

      assert [%{"id" => other_id}] =
               json_response(get(conn, "/api/v1/accounts/#{account.id}/following"), 200)

      assert other_id == to_string(other.id)
    end

    # Every assertion below is an empty list, which is what a broken request
    # returns as well. The two tests above are the positive controls: the same
    # endpoints, the same fixtures, answering in full.
    test "unless they hide who they follow and who follows them", %{
      conn: conn,
      other: other,
      account: account
    } do
      {:ok, _} = Relationships.follow(account, other)
      {:ok, other} = Accounts.update_account(other, %{hide_collections: true})

      assert json_response(get(conn, "/api/v1/accounts/#{other.id}/followers"), 200) == []
      assert json_response(get(conn, "/api/v1/accounts/#{other.id}/following"), 200) == []
    end

    test "and their owner still sees their own", %{conn: conn, account: account, other: other} do
      {:ok, _} = Relationships.follow(account, other)
      {:ok, _} = Accounts.update_account(account, %{hide_collections: true})

      assert [%{"id" => id}] =
               json_response(get(conn, "/api/v1/accounts/#{account.id}/following"), 200)

      assert id == to_string(other.id)
    end

    test "somebody they blocked is told nothing at all", %{
      conn: conn,
      other: other,
      account: account
    } do
      {:ok, _} = Relationships.follow(account, other)
      status_fixture(%{account_id: other.id, text: "public"})
      {:ok, _} = Relationships.block(other, account)

      assert json_response(get(conn, "/api/v1/accounts/#{other.id}/statuses"), 200) == []
      assert json_response(get(conn, "/api/v1/accounts/#{other.id}/followers"), 200) == []
      assert json_response(get(conn, "/api/v1/accounts/#{other.id}/following"), 200) == []
    end

    test "and the lists leave out whoever the reader blocked", %{
      conn: conn,
      other: other,
      account: account
    } do
      loud = account_fixture()
      {:ok, _} = Relationships.follow(loud, other)
      {:ok, _} = Relationships.follow(account, other)

      assert length(json_response(get(conn, "/api/v1/accounts/#{other.id}/followers"), 200)) == 2

      {:ok, _} = Relationships.block(account, loud)

      assert [%{"id" => id}] =
               json_response(get(conn, "/api/v1/accounts/#{other.id}/followers"), 200)

      assert id == to_string(account.id)
    end
  end

  describe "acting on somebody" do
    setup do
      %{other: account_fixture(%{username: "bob"})}
    end

    test "following answers with the relationship, not the account", %{conn: conn, other: other} do
      # A client turns its button into the new state from this answer.
      body = json_response(post(conn, "/api/v1/accounts/#{other.id}/follow"), 200)

      assert body["following"]
      assert body["id"] == to_string(other.id)
    end

    test "following a locked account asks rather than follows", %{conn: conn} do
      locked = account_fixture(%{username: "carol", locked: true})

      body = json_response(post(conn, "/api/v1/accounts/#{locked.id}/follow"), 200)

      refute body["following"]
      assert body["requested"]
    end

    test "asking a locked account twice is one request", %{conn: conn} do
      locked = account_fixture(%{username: "dora", locked: true})

      post(conn, "/api/v1/accounts/#{locked.id}/follow")
      body = json_response(post(conn, "/api/v1/accounts/#{locked.id}/follow"), 200)

      assert body["requested"]
    end

    # A follow already granted is changed by a repeat follow, on a locked
    # account like on any other. Asking again would leave a request pending
    # beside a follow that is already in place.
    test "setting the options on a follow a locked account granted", %{
      conn: conn,
      account: account
    } do
      locked = account_fixture(%{username: "elke", locked: true})
      {:ok, request} = Relationships.request_follow(account, locked)
      {:ok, _follow} = Relationships.accept_follow_request(request)

      body =
        json_response(
          post(conn, "/api/v1/accounts/#{locked.id}/follow", %{"reblogs" => false}),
          200
        )

      assert body["following"]
      refute body["requested"]
      refute body["showing_reblogs"]
    end

    test "unfollowing withdraws a request nobody has answered", %{conn: conn, account: account} do
      locked = account_fixture(%{username: "frida", locked: true})
      post(conn, "/api/v1/accounts/#{locked.id}/follow")

      body = json_response(post(conn, "/api/v1/accounts/#{locked.id}/unfollow"), 200)

      refute body["requested"]
      assert Relationships.get_follow_request(account, locked) == nil
    end

    test "carrying the per-follow options", %{conn: conn, other: other} do
      body =
        json_response(
          post(conn, "/api/v1/accounts/#{other.id}/follow", %{
            "reblogs" => false,
            "notify" => true
          }),
          200
        )

      refute body["showing_reblogs"]
      assert body["notifying"]
    end

    test "unfollowing", %{conn: conn, other: other} do
      post(conn, "/api/v1/accounts/#{other.id}/follow")

      refute json_response(post(conn, "/api/v1/accounts/#{other.id}/unfollow"), 200)["following"]
    end

    test "blocking and unblocking", %{conn: conn, other: other} do
      assert json_response(post(conn, "/api/v1/accounts/#{other.id}/block"), 200)["blocking"]
      refute json_response(post(conn, "/api/v1/accounts/#{other.id}/unblock"), 200)["blocking"]
    end

    test "muting, with a duration that runs out", %{conn: conn, other: other} do
      body =
        json_response(
          post(conn, "/api/v1/accounts/#{other.id}/mute", %{"duration" => "3600"}),
          200
        )

      assert body["muting"]
    end

    test "muting posts but not notifications, as a form sends it", %{conn: conn, other: other} do
      # `notifications=false` arrives as the string, and the check was
      # `params["notifications"] != false` -- true for every string there is.
      # So somebody who muted an account and asked to still be told when it
      # mentioned them was not told, and the answer said so plainly while
      # doing the opposite.
      body =
        json_response(
          post(conn, "/api/v1/accounts/#{other.id}/mute", %{"notifications" => "false"}),
          200
        )

      assert body["muting"]
      refute body["muting_notifications"]
    end

    test "and muting both when nothing is said about notifications", %{conn: conn, other: other} do
      # The default is the loud one: a client that says nothing wants the whole
      # mute, which is what the reference implementation does.
      body = json_response(post(conn, "/api/v1/accounts/#{other.id}/mute"), 200)

      assert body["muting"]
      assert body["muting_notifications"]
    end

    test "unmuting", %{conn: conn, other: other} do
      post(conn, "/api/v1/accounts/#{other.id}/mute")

      refute json_response(post(conn, "/api/v1/accounts/#{other.id}/unmute"), 200)["muting"]
    end

    test "a private note nobody else sees", %{conn: conn, other: other} do
      body =
        json_response(
          post(conn, "/api/v1/accounts/#{other.id}/note", %{"comment" => "met at a conference"}),
          200
        )

      assert body["note"] == "met at a conference"
    end

    test "removing a follower without blocking them", %{
      conn: conn,
      other: other,
      account: account
    } do
      {:ok, _} = Relationships.follow(other, account)

      body = json_response(post(conn, "/api/v1/accounts/#{other.id}/remove_from_followers"), 200)

      refute body["followed_by"]
      refute body["blocking"]
    end

    test "doing any of it to yourself is refused", %{conn: conn, account: account} do
      # A relationship that reported it as having worked would leave the button
      # in a state nothing can undo.
      for action <- ~w(follow block mute) do
        conn = post(conn, "/api/v1/accounts/#{account.id}/#{action}")

        assert json_response(conn, 422)["error"] =~ "yourself"
      end
    end
  end

  describe "relationships in bulk" do
    test "answers one per id asked about", %{conn: conn, account: account} do
      one = account_fixture()
      two = account_fixture()
      {:ok, _} = Relationships.follow(account, one)

      body =
        json_response(
          get(conn, "/api/v1/accounts/relationships", %{
            "id" => [to_string(one.id), to_string(two.id)]
          }),
          200
        )

      assert length(body) == 2
      assert Enum.find(body, &(&1["id"] == to_string(one.id)))["following"]
      refute Enum.find(body, &(&1["id"] == to_string(two.id)))["following"]
    end

    test "familiar followers", %{conn: conn, account: account} do
      friend = account_fixture()
      stranger = account_fixture()
      {:ok, _} = Relationships.follow(account, friend)
      {:ok, _} = Relationships.follow(friend, stranger)

      body =
        json_response(
          get(conn, "/api/v1/accounts/familiar_followers", %{"id" => [to_string(stranger.id)]}),
          200
        )

      assert [%{"accounts" => [%{"id" => id}]}] = body
      assert id == to_string(friend.id)
    end
  end

  describe "the settings lists" do
    setup %{account: account} do
      other = account_fixture()

      %{other: other, account: account}
    end

    test "who you blocked", %{conn: conn, account: account, other: other} do
      {:ok, _} = Relationships.block(account, other)

      assert [%{"id" => id}] = json_response(get(conn, "/api/v1/blocks"), 200)
      assert id == to_string(other.id)
    end

    test "who you muted", %{conn: conn, account: account, other: other} do
      {:ok, _} = Relationships.mute(account, other, %{})

      assert [%{"id" => id}] = json_response(get(conn, "/api/v1/mutes"), 200)
      assert id == to_string(other.id)
    end

    test "and until when, for a mute that lifts itself", %{
      conn: conn,
      account: account,
      other: other
    } do
      # `duration` has been accepted since mutes had one, and the answer never
      # said when the mute ends -- so a client could offer "mute for an hour"
      # and then had nothing to show for it afterwards, not even to itself.
      until = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, _} = Relationships.mute(account, other, %{expires_at: until})

      assert [entry] = json_response(get(conn, "/api/v1/mutes"), 200)
      assert {:ok, parsed, _} = DateTime.from_iso8601(entry["mute_expires_at"])
      assert DateTime.diff(parsed, until) == 0

      relationship =
        conn
        |> get("/api/v1/accounts/relationships", %{"id" => [to_string(other.id)]})
        |> json_response(200)
        |> List.first()

      assert {:ok, ^parsed, _} = DateTime.from_iso8601(relationship["muting_expires_at"])
    end

    test "and nothing where a mute does not end", %{conn: conn, account: account, other: other} do
      # The field is there and empty rather than absent, which is what a client
      # reads to mean "muted until I say otherwise".
      {:ok, _} = Relationships.mute(account, other, %{})

      assert [entry] = json_response(get(conn, "/api/v1/mutes"), 200)
      assert Map.has_key?(entry, "mute_expires_at")
      assert entry["mute_expires_at"] == nil
    end

    test "which domains you blocked, and blocking one", %{conn: conn} do
      assert json_response(
               post(conn, "/api/v1/domain_blocks", %{"domain" => "noisy.example"}),
               200
             )

      assert json_response(get(conn, "/api/v1/domain_blocks"), 200) == ["noisy.example"]

      delete(conn, "/api/v1/domain_blocks", %{"domain" => "noisy.example"})

      assert json_response(get(conn, "/api/v1/domain_blocks"), 200) == []
    end

    test "blocking no domain at all is refused", %{conn: conn} do
      assert json_response(post(conn, "/api/v1/domain_blocks", %{}), 422)["error"]
    end
  end

  describe "follow requests" do
    setup %{conn: conn, application: application} do
      locked = account_fixture(%{username: "locked", locked: true})
      asker = account_fixture(%{username: "asker"})
      {:ok, _} = Relationships.request_follow(asker, locked)

      %{
        conn: conn,
        locked_conn: authorize(build_conn(), application, locked),
        asker: asker,
        locked: locked
      }
    end

    test "lists who is waiting", %{locked_conn: conn, asker: asker} do
      assert [%{"id" => id}] = json_response(get(conn, "/api/v1/follow_requests"), 200)
      assert id == to_string(asker.id)
    end

    test "authorising lets them in", %{locked_conn: conn, asker: asker, locked: locked} do
      body = json_response(post(conn, "/api/v1/follow_requests/#{asker.id}/authorize"), 200)

      assert body["followed_by"]
      assert Relationships.following?(asker, locked)
    end

    test "rejecting turns them down", %{locked_conn: conn, asker: asker, locked: locked} do
      body = json_response(post(conn, "/api/v1/follow_requests/#{asker.id}/reject"), 200)

      refute body["followed_by"]
      refute Relationships.following?(asker, locked)
    end

    test "answering a request nobody made", %{locked_conn: conn} do
      assert json_response(post(conn, "/api/v1/follow_requests/999999/authorize"), 404)["error"]
    end
  end

  describe "finding somebody new" do
    test "the directory lists accounts that asked to be listed", %{conn: conn} do
      shown = account_fixture(%{username: "shown", discoverable: true})

      body = json_response(get(conn, "/api/v1/directory"), 200)

      assert Enum.any?(body, &(&1["id"] == to_string(shown.id)))
    end

    test "most recently active first, which is what clients ask for", %{conn: conn} do
      # Every client's "explore people" tab sends `order=active`, and the
      # parameter was silently ignored: whoever registered last stood first,
      # however long they had been quiet. The reference implementation's
      # default is active too, so the default here follows it.
      # The lively account registered first, so ordering by arrival puts it
      # last: this only passes if activity really decides. The first version
      # created them the other way round and passed against the unfixed code.
      lively = account_fixture(%{username: "lively", discoverable: true})
      quiet = account_fixture(%{username: "quiet", discoverable: true})

      put_last_status(quiet, DateTime.add(DateTime.utc_now(), -30, :day))
      put_last_status(lively, DateTime.add(DateTime.utc_now(), -1, :hour))

      ids =
        conn
        |> get("/api/v1/directory", %{"order" => "active"})
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert index_of(ids, lively.id) < index_of(ids, quiet.id)

      default_ids =
        conn |> get("/api/v1/directory") |> json_response(200) |> Enum.map(& &1["id"])

      assert index_of(default_ids, lively.id) < index_of(default_ids, quiet.id)
    end

    test "or newest first when asked", %{conn: conn} do
      older = account_fixture(%{username: "older", discoverable: true})
      newer = account_fixture(%{username: "newer", discoverable: true})

      # The older account is the busier one, so this only passes if `new`
      # really orders by arrival rather than by activity.
      put_last_status(older, DateTime.utc_now())

      ids =
        conn
        |> get("/api/v1/directory", %{"order" => "new"})
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert index_of(ids, newer.id) < index_of(ids, older.id)
    end

    test "and never anybody from another server, whatever is asked", %{conn: conn} do
      # Deliberately narrower than the reference implementation, which lists
      # remote discoverables: somebody elsewhere set that flag for their own
      # server's directory and never agreed to appear in ours. `local=true`
      # is satisfied trivially rather than being a switch.
      remote =
        remote_account_fixture(%{username: "far", domain: "remote.example", discoverable: true})

      for query <- [%{}, %{"local" => "true"}, %{"local" => "false"}] do
        ids =
          conn |> get("/api/v1/directory", query) |> json_response(200) |> Enum.map(& &1["id"])

        refute to_string(remote.id) in ids, "a remote account appeared for #{inspect(query)}"
      end
    end

    defp put_last_status(account, at) do
      Abuuba.Repo.insert_all(
        "account_stats",
        [%{account_id: account.id, last_status_at: at, inserted_at: at, updated_at: at}],
        on_conflict: {:replace, [:last_status_at]},
        conflict_target: [:account_id]
      )
    end

    defp index_of(ids, id), do: Enum.find_index(ids, &(&1 == to_string(id))) || 9_999

    test "suggestions and endorsements answer with nothing rather than a 404", %{conn: conn} do
      # A client that gets a 404 shows an error where it meant to show nothing.
      assert json_response(get(conn, "/api/v1/suggestions"), 200) == []
      assert json_response(get(conn, "/api/v1/endorsements"), 200) == []
    end
  end
end
