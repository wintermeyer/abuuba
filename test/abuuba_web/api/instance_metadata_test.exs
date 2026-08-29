defmodule AbuubaWeb.API.InstanceMetadataTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.OAuth
  alias Abuuba.Relationships
  alias Abuuba.Settings

  setup %{conn: conn} do
    account = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write", "follow"])

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> raw),
      anon: build_conn(),
      account: account
    }
  end

  describe "documents about the server" do
    test "the privacy policy answers like the other documents", %{anon: anon} do
      Settings.put("privacy_text", "We keep what you write and nothing else.")

      body = json_response(get(anon, "/api/v1/instance/privacy_policy"), 200)

      assert body["content"] =~ "nothing else"
      assert Map.has_key?(body, "updated_at")
    end

    test "an unwritten policy is empty rather than missing", %{anon: anon} do
      # A 404 reads as "this server will not say", which is a different claim.
      assert %{"content" => ""} = json_response(get(anon, "/api/v1/instance/privacy_policy"), 200)
    end

    test "the interface languages come with their own names", %{anon: anon} do
      body = json_response(get(anon, "/api/v1/instance/languages"), 200)

      # Its own name, because somebody scanning a picker for their language is
      # looking for the word they would write it with.
      assert %{"code" => "de", "name" => "Deutsch"} in body
      assert %{"code" => "en", "name" => "English"} in body
    end
  end

  describe "finding a server by name" do
    test "completes on the domains this server has met", %{anon: anon} do
      remote_account_fixture(%{domain: "mastodon.social"})
      remote_account_fixture(%{domain: "mastodon.online"})
      remote_account_fixture(%{domain: "elsewhere.example"})

      assert body = json_response(get(anon, "/api/v1/peers/search", %{"q" => "mastodon."}), 200)

      assert Enum.sort(body) == ["mastodon.online", "mastodon.social"]
    end

    test "an empty query answers with nothing, not with everything", %{anon: anon} do
      # A completion box that fills itself before anybody types is not one.
      remote_account_fixture(%{domain: "somewhere.example"})

      assert json_response(get(anon, "/api/v1/peers/search", %{"q" => ""}), 200) == []
      assert json_response(get(anon, "/api/v1/peers/search", %{}), 200) == []
    end

    test "a wildcard somebody typed is not a wildcard", %{anon: anon} do
      remote_account_fixture(%{domain: "anything.example"})

      assert json_response(get(anon, "/api/v1/peers/search", %{"q" => "%"}), 200) == []
    end
  end

  describe "what blocking a domain would cost" do
    test "counts the follows in both directions", %{conn: conn, account: account} do
      theirs = remote_account_fixture(%{domain: "noisy.example"})
      other = remote_account_fixture(%{domain: "noisy.example"})
      elsewhere = remote_account_fixture(%{domain: "quiet.example"})

      {:ok, _} = Relationships.follow(account, theirs)
      {:ok, _} = Relationships.follow(account, elsewhere)
      {:ok, _} = Relationships.follow(other, account)

      body =
        json_response(
          get(conn, "/api/v1/domain_blocks/preview", %{"domain" => "noisy.example"}),
          200
        )

      assert body["following_count"] == 1
      assert body["followers_count"] == 1
    end

    test "needs a token: it is a fact about the asker", %{anon: anon} do
      assert json_response(get(anon, "/api/v1/domain_blocks/preview", %{"domain" => "x"}), 422)
    end
  end

  describe "the trends alias" do
    test "answers with tags for a client written before the namespace", %{anon: anon} do
      assert is_list(json_response(get(anon, "/api/v1/trends"), 200))
    end
  end

  describe "suggestions" do
    setup %{account: account} do
      # Somebody the reader follows, who follows somebody the reader does not.
      friend = account_fixture()
      candidate = account_fixture(%{discoverable: true})

      {:ok, _} = Relationships.follow(account, friend)
      {:ok, _} = Relationships.follow(friend, candidate)

      %{friend: friend, candidate: candidate}
    end

    test "names the people the reader's own follows follow", %{
      conn: conn,
      candidate: candidate
    } do
      assert [%{"id" => id}] = json_response(get(conn, "/api/v1/suggestions"), 200)
      assert id == to_string(candidate.id)
    end

    test "the v2 shape says where the suggestion came from", %{conn: conn, candidate: candidate} do
      assert [entry] = json_response(get(conn, "/api/v2/suggestions"), 200)

      assert entry["account"]["id"] == to_string(candidate.id)
      assert entry["sources"] == ["friends_of_friends"]
      assert is_binary(entry["source"])
    end

    test "dismissing one keeps it dismissed", %{conn: conn, candidate: candidate} do
      # The list is computed on every request, so a dismissal nobody wrote down
      # lasts until the column reloads.
      assert json_response(delete(conn, "/api/v1/suggestions/#{candidate.id}"), 200) == %{}

      assert json_response(get(conn, "/api/v1/suggestions"), 200) == []
      assert json_response(get(conn, "/api/v2/suggestions"), 200) == []
    end

    test "never suggests somebody already followed, blocked or muted", %{
      conn: conn,
      account: account,
      friend: friend
    } do
      blocked = account_fixture(%{discoverable: true})
      muted = account_fixture(%{discoverable: true})
      hidden = account_fixture(%{discoverable: false})

      for target <- [blocked, muted, hidden], do: Relationships.follow(friend, target)
      {:ok, _} = Relationships.block(account, blocked)
      {:ok, _} = Relationships.mute(account, muted)

      ids = conn |> get("/api/v1/suggestions") |> json_response(200) |> Enum.map(& &1["id"])

      refute to_string(blocked.id) in ids
      refute to_string(muted.id) in ids
      refute to_string(hidden.id) in ids
      refute to_string(friend.id) in ids
      refute to_string(account.id) in ids
    end

    test "needs a token", %{anon: anon} do
      assert json_response(get(anon, "/api/v1/suggestions"), 422)
    end
  end
end
