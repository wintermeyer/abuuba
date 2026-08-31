defmodule AbuubaWeb.API.SearchControllerTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.PostingDefaults
  alias Abuuba.Accounts.Preferences
  alias Abuuba.Instance
  alias Abuuba.Moderation.Domains
  alias Abuuba.OAuth
  alias Abuuba.Settings
  alias Abuuba.Statuses
  alias Abuuba.Trends

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
      account: account
    }
  end

  describe "search" do
    test "finds accounts, hashtags and posts from one query", %{conn: conn, account: account} do
      # A person types one thing into one box and does not know which of the
      # three they are looking for.
      status = status_fixture(%{account_id: account.id, text: "alice was here"})
      tag = tag_fixture("alicecore")
      :ok = Statuses.tag_status(status, tag)

      body = json_response(get(conn, "/api/v2/search", %{"q" => "alice"}), 200)

      assert [%{"username" => "alice"}] = body["accounts"]
      assert [%{"name" => "alicecore"}] = body["hashtags"]
      assert [%{"content" => "<p>alice was here</p>"}] = body["statuses"]
    end

    test "account_id narrows posts to one author", %{conn: conn, account: account} do
      # What an app sends for "search within this profile". It was accepted and
      # ignored, so the answer was everybody's posts -- which looks like an
      # answer rather than like a refusal, and is the worse of the two.
      other = account_fixture(%{username: "bob"})

      status_fixture(%{account_id: account.id, text: "a shared word"})
      status_fixture(%{account_id: other.id, text: "a shared word too"})

      body =
        json_response(
          get(conn, "/api/v2/search", %{
            "q" => "shared",
            "type" => "statuses",
            "account_id" => to_string(other.id)
          }),
          200
        )

      assert [%{"content" => content}] = body["statuses"]
      assert content =~ "too"
    end

    test "following narrows accounts to people you follow", %{conn: conn, account: account} do
      followed = account_fixture(%{username: "bobfollowed"})
      _stranger = account_fixture(%{username: "bobstranger"})
      {:ok, _follow} = Abuuba.Relationships.follow(account, followed)

      body =
        json_response(
          get(conn, "/api/v2/search", %{
            "q" => "bob",
            "type" => "accounts",
            "following" => "true"
          }),
          200
        )

      assert [%{"username" => "bobfollowed"}] = body["accounts"]
    end

    test "and without it both are found", %{conn: conn, account: account} do
      # The control. A filter that is always on would pass the test above and
      # quietly hide everybody a person has not followed.
      followed = account_fixture(%{username: "bobfollowed"})
      _stranger = account_fixture(%{username: "bobstranger"})
      {:ok, _follow} = Abuuba.Relationships.follow(account, followed)

      body =
        json_response(get(conn, "/api/v2/search", %{"q" => "bob", "type" => "accounts"}), 200)

      assert length(body["accounts"]) == 2
    end

    test "exclude_unreviewed leaves out hashtags nobody has looked at", %{conn: conn} do
      reviewed = tag_fixture("aliceseen")
      _unreviewed = tag_fixture("aliceunseen")

      {:ok, _tag} =
        reviewed
        |> Ecto.Changeset.change(reviewed_at: DateTime.utc_now())
        |> Abuuba.Repo.update()

      body =
        json_response(
          get(conn, "/api/v2/search", %{
            "q" => "alice",
            "type" => "hashtags",
            "exclude_unreviewed" => "true"
          }),
          200
        )

      assert [%{"name" => "aliceseen"}] = body["hashtags"]
    end

    test "can be narrowed to one kind", %{conn: conn} do
      body =
        json_response(get(conn, "/api/v2/search", %{"q" => "alice", "type" => "accounts"}), 200)

      assert body["accounts"] != []
      assert body["statuses"] == []
      assert body["hashtags"] == []
    end

    test "an empty query finds nothing rather than everything", %{conn: conn} do
      body = json_response(get(conn, "/api/v2/search", %{"q" => "  "}), 200)

      assert body == %{"accounts" => [], "statuses" => [], "hashtags" => []}
    end

    test "a URL is resolved rather than matched as words", %{conn: conn, account: account} do
      # Searching for the literal text of a URL finds nothing, and pasting a
      # link is how somebody brings something into view.
      status =
        status_fixture(%{
          account_id: account.id,
          uri: "https://remote.example/statuses/1",
          local: false
        })

      body =
        json_response(
          get(conn, "/api/v2/search", %{"q" => "https://remote.example/statuses/1"}),
          200
        )

      assert [%{"id" => id}] = body["statuses"]
      assert id == to_string(status.id)
    end

    test "and a pasted URL does not hand over a post its address alone names", %{
      anon: anon,
      conn: conn,
      account: account
    } do
      # Resolving by address read the post through the unchecked lookup --
      # `Abuuba.Statuses.get_status_unchecked_by_uri/1`, whose own docstring
      # says "never for rendering" -- and handed it straight to the entity
      # renderer, which asks nothing about who is reading. Anybody holding the
      # address of a followers-only post could read it by pasting it in, with
      # no account at all.
      secret =
        status_fixture(%{
          account_id: account.id,
          text: "kryptonite",
          visibility: :private,
          uri: "https://remote.example/statuses/secret",
          local: false
        })

      url = "https://remote.example/statuses/secret"

      assert json_response(get(anon, "/api/v2/search", %{"q" => url}), 200)["statuses"] == []

      # The positive half: its author still finds it, so an empty list above
      # is the check and not a lookup that stopped working.
      assert [%{"id" => id}] =
               json_response(get(conn, "/api/v2/search", %{"q" => url}), 200)["statuses"]

      assert id == to_string(secret.id)
    end

    test "offset needs a token, because it is how a box becomes a crawler", %{anon: anon} do
      conn = get(anon, "/api/v2/search", %{"q" => "alice", "offset" => "20"})

      assert json_response(conn, 401)["error"]
    end

    test "resolve needs a token, because it spends somebody else's bandwidth", %{anon: anon} do
      conn = get(anon, "/api/v2/search", %{"q" => "alice", "resolve" => "true"})

      assert json_response(conn, 401)["error"]
    end

    test "a plain search works without one", %{anon: anon} do
      assert json_response(get(anon, "/api/v2/search", %{"q" => "alice"}), 200)["accounts"] != []
    end

    test "does not find somebody else's private post", %{conn: conn} do
      other = account_fixture()
      status_fixture(%{account_id: other.id, text: "secret alice", visibility: :private})

      body = json_response(get(conn, "/api/v2/search", %{"q" => "secret"}), 200)

      assert body["statuses"] == []
    end

    test "takes a wildcard literally", %{conn: conn, account: account} do
      status_fixture(%{account_id: account.id, text: "100% sure"})

      body = json_response(get(conn, "/api/v2/search", %{"q" => "100%"}), 200)

      assert [%{"content" => "<p>100% sure</p>"}] = body["statuses"]
    end
  end

  describe "the informational endpoints" do
    test "custom emojis lists local, enabled ones", %{conn: conn} do
      {:ok, _} = Instance.put_custom_emoji(%{shortcode: "blobcat", image_url: "https://x/1.png"})

      {:ok, _} =
        Instance.put_custom_emoji(%{
          shortcode: "elsewhere",
          domain: "remote.example",
          image_url: "https://y/1.png"
        })

      body = json_response(get(conn, "/api/v1/custom_emojis"), 200)

      assert Enum.map(body, & &1["shortcode"]) == ["blobcat"]
    end

    test "two servers may both have a blobcat" do
      # A global unique index would make the second one we heard of unstorable,
      # and posts carrying it would render with the wrong picture or none.
      {:ok, _} = Instance.put_custom_emoji(%{shortcode: "blobcat", image_url: "https://x/1.png"})

      assert {:ok, _} =
               Instance.put_custom_emoji(%{
                 shortcode: "blobcat",
                 domain: "remote.example",
                 image_url: "https://y/1.png"
               })
    end

    test "preferences answer what a compose box should default to", %{conn: conn} do
      body = json_response(get(conn, "/api/v1/preferences"), 200)

      assert body["posting:default:visibility"] == "public"
      assert body["posting:default:quote_policy"] == "public"
    end

    test "and answer with what this person actually set", %{conn: conn, account: account} do
      # Every posting key here was a constant, so somebody whose posts should
      # all be followers-only was told "public" by every app that asked. The
      # compose box in this server's own interface reads the stored value, so
      # the two disagreed about the same setting -- and the direction of the
      # disagreement is the one that matters, because a client believing
      # "public" is how something meant for followers gets posted to everybody.
      user = Abuuba.Repo.get_by!(Abuuba.Accounts.User, account_id: account.id)

      settings =
        PostingDefaults.merge(user.settings, %{
          "visibility" => "private",
          "quote_policy" => "nobody",
          "language" => "de",
          "sensitive" => true
        })

      {:ok, user} = Accounts.update_user_settings(user, settings)

      {:ok, _} =
        Accounts.update_user_settings(
          user,
          Preferences.merge(user.settings, %{"disable_autoplay" => true})
        )

      body = json_response(get(conn, "/api/v1/preferences"), 200)

      assert body["posting:default:visibility"] == "private"
      assert body["posting:default:quote_policy"] == "nobody"
      assert body["posting:default:language"] == "de"
      assert body["posting:default:sensitive"] == true
      assert body["reading:autoplay:gifs"] == false
    end

    test "the extended description says when it was written", %{conn: conn} do
      # A client caches the about page and asks whether it has moved on. `nil`
      # reads as "never written", so text an admin changed this morning looked
      # like text nobody had ever set.
      before = json_response(get(conn, "/api/v1/instance/extended_description"), 200)
      assert before["updated_at"] == nil

      :ok = Settings.put("extended_description", "A server for gardeners.")

      body = json_response(get(conn, "/api/v1/instance/extended_description"), 200)

      assert body["content"] == "A server for gardeners."
      assert {:ok, _, _} = DateTime.from_iso8601(body["updated_at"])
    end

    test "peers names the servers this one has heard from", %{conn: conn} do
      remote_account_fixture(%{username: "bob", domain: "remote.example"})

      assert "remote.example" in json_response(get(conn, "/api/v1/instance/peers"), 200)
    end

    test "the endpoints with nothing to say answer with nothing, not a 404", %{conn: conn} do
      # A client that gets a 404 shows an error where it meant to show nothing.
      # domain_blocks is in the list only when an admin has opened it: by
      # default the endpoint is 404, which under this setting means "this
      # server does not say", not "nothing blocked".
      :ok = Settings.put("show_domain_blocks", "all")

      for path <- ~w(
            /api/v1/instance/domain_blocks
            /api/v1/trends/tags
            /api/v1/trends/statuses
            /api/v1/trends/links
          ) do
        assert json_response(get(conn, path), 200) == [], "failed for #{path}"
      end

      # The activity graph's "nothing" is twelve weeks of zeros rather than an
      # empty list: a chart drawn from it is a flat line, which is the honest
      # shape of a quiet server, where an empty list is a missing one.
      body = json_response(get(conn, "/api/v1/instance/activity"), 200)
      assert length(body) == 12
    end
  end

  describe "who may read the blocklist" do
    setup do
      account = account_fixture()

      user =
        user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

      {:ok, application, _secret} =
        OAuth.create_application(%{name: "t", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

      {:ok, _token, raw} = OAuth.issue_token(application, user, ["read"])

      on_exit(fn -> Settings.put("show_domain_blocks", "disabled") end)

      %{bearer: raw}
    end

    test "nobody, until an admin decides otherwise" do
      conn = build_conn()

      # The list is a record of moderation decisions, and naming the servers a
      # moderator acted against is exactly what invites their users to come and
      # argue about it -- the same reason single blocks can be obfuscated. The
      # reference implementation does not publish it by default either, and a
      # 404 here means "this server does not say".
      assert conn |> get("/api/v1/instance/domain_blocks") |> response(404)
    end

    test "the people who live here, when it is set to users", %{bearer: bearer} do
      conn = build_conn()

      :ok = Settings.put("show_domain_blocks", "users")

      # A stranger is told nothing -- not even that there is something being
      # withheld, which a 401 would say. A bare conn, because this file's
      # setup signs the default one in.
      assert build_conn() |> get("/api/v1/instance/domain_blocks") |> response(404)

      assert conn
             |> put_req_header("authorization", "Bearer " <> bearer)
             |> get("/api/v1/instance/domain_blocks")
             |> json_response(200)
    end

    test "anybody, when it is set to all", %{conn: conn} do
      :ok = Settings.put("show_domain_blocks", "all")

      moderator = account_fixture()

      {:ok, _} =
        Domains.block(moderator, %{
          "domain" => "bad.example",
          "severity" => "suspend"
        })

      body = conn |> get("/api/v1/instance/domain_blocks") |> json_response(200)

      assert Enum.any?(body, &(&1["domain"] == "bad.example"))
    end
  end

  describe "announcements" do
    setup do
      {:ok, announcement} =
        Instance.create_announcement(%{text: "Server maintenance Sunday", published: true})

      %{announcement: announcement}
    end

    test "lists what is current", %{conn: conn, announcement: announcement} do
      assert [%{"id" => id}] = json_response(get(conn, "/api/v1/announcements"), 200)
      assert id == to_string(announcement.id)
    end

    test "an unpublished one is not current" do
      {:ok, _} = Instance.create_announcement(%{text: "draft", published: false})

      assert length(Instance.announcements()) == 1
    end

    test "one whose window has closed stops being shown" do
      # What makes "the server is down on Sunday" stop appearing on Monday
      # without anybody remembering to take it down.
      {:ok, _} =
        Instance.create_announcement(%{
          text: "over",
          published: true,
          ends_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      refute Enum.any?(Instance.announcements(), &(&1.text == "over"))
    end

    test "dismissing hides it for one person only", %{
      conn: conn,
      announcement: announcement,
      account: account
    } do
      assert json_response(post(conn, "/api/v1/announcements/#{announcement.id}/dismiss"), 200)
      assert json_response(get(conn, "/api/v1/announcements"), 200) == []

      refute Instance.announcement_read?(announcement, account_fixture())
      assert Instance.announcement_read?(announcement, account)
    end

    test "reacting counts people and says whether you are one", %{
      conn: conn,
      announcement: announcement,
      account: account
    } do
      put(conn, "/api/v1/announcements/#{announcement.id}/reactions/%F0%9F%8E%89")

      assert [%{name: "🎉", count: 1, me: true}] =
               Instance.announcement_reactions(announcement, account)

      assert [%{me: false}] = Instance.announcement_reactions(announcement, account_fixture())
    end

    test "taking a reaction back", %{conn: conn, announcement: announcement, account: account} do
      put(conn, "/api/v1/announcements/#{announcement.id}/reactions/%F0%9F%8E%89")
      delete(conn, "/api/v1/announcements/#{announcement.id}/reactions/%F0%9F%8E%89")

      assert Instance.announcement_reactions(announcement, account) == []
    end
  end

  describe "following a tag" do
    setup do
      %{tag: tag_fixture("cycling")}
    end

    test "puts it in the followed list", %{conn: conn, tag: tag, account: account} do
      body = json_response(post(conn, "/api/v1/tags/#{tag.name}/follow"), 200)

      assert body["following"]
      assert Statuses.following_tag?(account, tag)

      assert [%{"name" => "cycling"}] = json_response(get(conn, "/api/v1/followed_tags"), 200)
    end

    test "unfollowing takes it back out", %{conn: conn, tag: tag} do
      post(conn, "/api/v1/tags/#{tag.name}/follow")

      refute json_response(post(conn, "/api/v1/tags/#{tag.name}/unfollow"), 200)["following"]
      assert json_response(get(conn, "/api/v1/followed_tags"), 200) == []
    end

    test "a tag nobody used is not there", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/tags/nothinghere"), 404)["error"]
    end

    test "reading one says whether you follow it", %{conn: conn, tag: tag} do
      refute json_response(get(conn, "/api/v1/tags/#{tag.name}"), 200)["following"]
    end

    test "and whether you have put it on your profile", %{conn: conn, tag: tag, account: account} do
      # A client draws one control for following a hashtag and another for
      # featuring it. Without this the second one has nothing to read, so it
      # renders as "not featured" for a tag sitting on the person's own profile.
      refute json_response(get(conn, "/api/v1/tags/#{tag.name}"), 200)["featuring"]

      :ok = Statuses.feature_tag(account, tag)

      assert json_response(get(conn, "/api/v1/tags/#{tag.name}"), 200)["featuring"]
    end

    test "and carries an id", %{conn: conn, tag: tag} do
      assert json_response(get(conn, "/api/v1/tags/#{tag.name}"), 200)["id"] == to_string(tag.id)
    end

    test "and the week of use a client draws the graph from", %{conn: conn, tag: tag} do
      # `history` was an empty list whatever the tag had done, so every
      # trending hashtag drew a flat line. The counts were being written the
      # whole time -- the trends screen is built on them.
      today = Date.utc_today()

      :ok = Trends.put_counts("tag", tag.name, today, uses: 5, accounts: 3)
      :ok = Trends.put_counts("tag", tag.name, Date.add(today, -1), uses: 2, accounts: 2)

      body = json_response(get(conn, "/api/v1/tags/#{tag.name}"), 200)

      assert length(body["history"]) == 7

      # Newest first, and every value a string, which is the shape clients
      # parse.
      assert [%{"day" => day, "uses" => "5", "accounts" => "3"} | rest] = body["history"]
      assert day == to_string(DateTime.to_unix(DateTime.new!(today, ~T[00:00:00])))
      assert [%{"uses" => "2", "accounts" => "2"} | _] = rest

      # A day nobody used it is a zero rather than a gap.
      assert Enum.all?(body["history"], &match?(%{"uses" => _, "accounts" => _}, &1))
    end
  end
end
