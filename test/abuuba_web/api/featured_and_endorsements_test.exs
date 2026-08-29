defmodule AbuubaWeb.API.FeaturedAndEndorsementsTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Lists
  alias Abuuba.OAuth
  alias Abuuba.Relationships
  alias Abuuba.Statuses

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

  # The hashtag in the text is what makes the link; posting is how a tag comes
  # to be used at all, so the fixture posts rather than writing the join row.
  defp tagged(account, name, opts \\ []) do
    status_fixture(Enum.into(opts, %{account_id: account.id, text: "something about ##{name}"}))

    Statuses.get_tag(name)
  end

  describe "featuring a tag" do
    test "adds one, lists it, and takes it off again", %{conn: conn, account: account} do
      created =
        json_response(post(conn, "/api/v1/featured_tags", %{"name" => "gardening"}), 200)

      assert created["name"] == "gardening"
      assert created["url"] =~ "/@alice/tagged/gardening"
      assert is_binary(created["id"])

      assert [listed] = json_response(get(conn, "/api/v1/featured_tags"), 200)
      assert listed["id"] == created["id"]

      assert json_response(delete(conn, "/api/v1/featured_tags/#{created["id"]}"), 200) == %{}
      assert json_response(get(conn, "/api/v1/featured_tags"), 200) == []
      assert Statuses.featured_tags(account) == []
    end

    test "counts the posts under it, as a string, with the date of the last", %{
      conn: conn,
      account: account
    } do
      # Both shapes are the reference implementation's, and clients parse them:
      # a number here or a full timestamp there is a client showing "NaN".
      tag = tagged(account, "gardening")
      tagged(account, "gardening")

      :ok = Statuses.feature_tag(account, tag)

      assert [featured] = json_response(get(conn, "/api/v1/featured_tags"), 200)
      assert featured["statuses_count"] == "2"
      assert featured["last_status_at"] =~ ~r/\A\d{4}-\d{2}-\d{2}\z/
    end

    test "does not count posts the reader of a profile cannot see", %{
      conn: conn,
      account: account
    } do
      # The count is on a public profile. Counting followers-only posts would
      # publish how much somebody writes where nobody can check it.
      tag = tagged(account, "quiet")
      tagged(account, "quiet", visibility: "private")

      :ok = Statuses.feature_tag(account, tag)

      assert [%{"statuses_count" => "1"}] = json_response(get(conn, "/api/v1/featured_tags"), 200)
    end

    test "leads with the tag actually used most", %{conn: conn, account: account} do
      rare = tagged(account, "rare")
      common = tagged(account, "common")
      tagged(account, "common")

      :ok = Statuses.feature_tag(account, rare)
      :ok = Statuses.feature_tag(account, common)

      assert [%{"name" => "common"}, %{"name" => "rare"}] =
               json_response(get(conn, "/api/v1/featured_tags"), 200)
    end

    test "cannot be deleted off somebody else's profile", %{conn: conn} do
      stranger = account_fixture()
      {:ok, tag} = Statuses.upsert_tag("theirs")
      :ok = Statuses.feature_tag(stranger, tag)

      [featured] = Statuses.featured_tags(stranger)

      assert json_response(delete(conn, "/api/v1/featured_tags/#{featured.id}"), 404)
      assert [_still_there] = Statuses.featured_tags(stranger)
    end

    test "by name, for a client that has the tag rather than the row", %{
      conn: conn,
      account: account
    } do
      assert %{"name" => "cycling"} =
               json_response(post(conn, "/api/v1/tags/cycling/feature", %{}), 200)

      assert [%{tag: %{name: "cycling"}}] = Statuses.featured_tags(account)

      assert %{"name" => "cycling"} =
               json_response(post(conn, "/api/v1/tags/cycling/unfeature", %{}), 200)

      assert Statuses.featured_tags(account) == []
    end

    test "suggests tags this person uses and has not featured", %{conn: conn, account: account} do
      used_twice = tagged(account, "often")
      tagged(account, "often")
      tagged(account, "once")

      already = tagged(account, "already")
      tagged(account, "already")
      :ok = Statuses.feature_tag(account, already)

      names =
        conn
        |> get("/api/v1/featured_tags/suggestions")
        |> json_response(200)
        |> Enum.map(& &1["name"])

      assert "often" in names
      # Used once is not what somebody is about, and one already on the profile
      # is not a suggestion.
      refute "once" in names
      refute "already" in names
      assert used_twice
    end

    test "stops at the limit the instance document advertises", %{conn: conn} do
      for n <- 1..Statuses.featured_tags_max() do
        assert json_response(post(conn, "/api/v1/featured_tags", %{"name" => "tag#{n}"}), 200)
      end

      assert json_response(post(conn, "/api/v1/featured_tags", %{"name" => "onetoomany"}), 422)
    end

    test "names the profile it belongs to, not a local account with the same name", %{
      anon: anon
    } do
      # A remote alice and a local alice are two people, and a URL built from
      # this server plus a bare username sends readers to the wrong one.
      remote = remote_account_fixture(%{username: "alice", domain: "remote.example"})
      {:ok, tag} = Statuses.upsert_tag("food")
      :ok = Statuses.feature_tag(remote, tag)

      assert [%{"url" => url}] =
               json_response(get(anon, "/api/v1/accounts/#{remote.id}/featured_tags"), 200)

      assert url =~ "remote.example"
    end

    test "somebody else's are readable without a token", %{anon: anon} do
      stranger = account_fixture()
      {:ok, tag} = Statuses.upsert_tag("theirs")
      :ok = Statuses.feature_tag(stranger, tag)

      assert [%{"name" => "theirs"}] =
               json_response(get(anon, "/api/v1/accounts/#{stranger.id}/featured_tags"), 200)
    end
  end

  describe "endorsing somebody" do
    # An endorsement is "follow this person too", so there is always a follow
    # under it. See `Abuuba.Relationships.endorse/2`.
    defp followed_by(account) do
      target = account_fixture()
      {:ok, _} = Relationships.follow(account, target)

      target
    end

    test "puts them on the profile and takes them off again", %{conn: conn, account: account} do
      target = followed_by(account)

      relationship =
        json_response(post(conn, "/api/v1/accounts/#{target.id}/endorse", %{}), 200)

      assert relationship["endorsed"] == true
      assert [%{"id" => id}] = json_response(get(conn, "/api/v1/endorsements"), 200)
      assert id == to_string(target.id)

      assert %{"endorsed" => false} =
               json_response(post(conn, "/api/v1/accounts/#{target.id}/unendorse", %{}), 200)

      assert json_response(get(conn, "/api/v1/endorsements"), 200) == []
      refute Relationships.endorsed?(account, target)
    end

    test "answers to the older spelling too", %{conn: conn, account: account} do
      target = followed_by(account)

      assert %{"endorsed" => true} =
               json_response(post(conn, "/api/v1/accounts/#{target.id}/pin", %{}), 200)

      assert Relationships.endorsed?(account, target)

      assert %{"endorsed" => false} =
               json_response(post(conn, "/api/v1/accounts/#{target.id}/unpin", %{}), 200)
    end

    test "twice is once", %{conn: conn, account: account} do
      target = followed_by(account)

      assert json_response(post(conn, "/api/v1/accounts/#{target.id}/endorse", %{}), 200)
      assert json_response(post(conn, "/api/v1/accounts/#{target.id}/endorse", %{}), 200)

      assert [_one] = Relationships.endorsements(account, %{})
    end

    test "cannot endorse yourself", %{conn: conn, account: account} do
      assert json_response(post(conn, "/api/v1/accounts/#{account.id}/endorse", %{}), 422)
    end

    test "somebody else's are readable without a token", %{anon: anon} do
      stranger = account_fixture()
      target = account_fixture()
      {:ok, _} = Relationships.follow(stranger, target)
      :ok = Relationships.endorse(stranger, target)

      assert [%{"id" => id}] =
               json_response(get(anon, "/api/v1/accounts/#{stranger.id}/endorsements"), 200)

      assert id == to_string(target.id)
    end

    test "a suspended account stops being recommended", %{conn: conn, account: account} do
      # Continuing to recommend somebody this server has taken down is the one
      # thing an endorsement must not keep doing on its owner's behalf.
      target = followed_by(account)
      :ok = Relationships.endorse(account, target)

      {:ok, _} = Abuuba.Accounts.update_moderation(target, %{suspended_at: DateTime.utc_now()})

      assert json_response(get(conn, "/api/v1/endorsements"), 200) == []
    end

    test "needs a follow behind it", %{conn: conn, account: account} do
      # Otherwise anybody blocked can go on naming the person who blocked them,
      # on their own profile, publicly, forever.
      stranger = account_fixture()

      assert %{"error" => message} =
               json_response(post(conn, "/api/v1/accounts/#{stranger.id}/endorse", %{}), 422)

      assert message =~ "follow"
      refute Relationships.endorsed?(account, stranger)
    end

    test "falls away when the follow does", %{conn: conn, account: account} do
      target = followed_by(account)
      :ok = Relationships.endorse(account, target)

      :ok = Relationships.unfollow(account, target)

      refute Relationships.endorsed?(account, target)
      assert json_response(get(conn, "/api/v1/endorsements"), 200) == []
    end

    test "falls away when they block you", %{account: account} do
      target = followed_by(account)
      :ok = Relationships.endorse(account, target)

      {:ok, _} = Relationships.block(target, account)

      refute Relationships.endorsed?(account, target)
    end

    test "needs a token of its own", %{anon: anon} do
      assert json_response(get(anon, "/api/v1/endorsements"), 422)
    end
  end

  describe "the rest of the account family" do
    test "says which of my own lists somebody is in", %{conn: conn, account: account} do
      member = account_fixture()
      {:ok, _} = Relationships.follow(account, member)
      {:ok, list} = Lists.create(account, %{"title" => "Cycling"})
      :ok = Lists.add(list, [member.id])

      # Somebody else's list, which must not appear: whose lists a person is in
      # is nobody else's business.
      stranger = account_fixture()
      {:ok, _} = Relationships.follow(stranger, member)
      {:ok, theirs} = Lists.create(stranger, %{"title" => "Theirs"})
      :ok = Lists.add(theirs, [member.id])

      assert [%{"title" => "Cycling"}] =
               json_response(get(conn, "/api/v1/accounts/#{member.id}/lists"), 200)
    end

    test "identity proofs is an empty list rather than a missing route", %{anon: anon} do
      stranger = account_fixture()

      assert json_response(get(anon, "/api/v1/accounts/#{stranger.id}/identity_proofs"), 200) ==
               []
    end
  end
end
