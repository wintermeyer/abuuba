defmodule AbuubaWeb.API.OAuthScopesTest do
  @moduledoc """
  What a token's scopes are actually worth.

  Every assertion here that something is refused is paired with the same
  request succeeding for a token that asked for the right thing. A suite of
  refusals alone would pass just as happily against a server that refused
  everything, or against one where the requests never arrived.
  """

  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.OAuth
  alias Abuuba.Roles

  setup %{conn: conn} do
    %{conn: put_req_header(conn, "accept", "application/json")}
  end

  defp token(scopes) do
    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, scopes)

    {account, raw}
  end

  defp as(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp moderator_token(scopes) do
    {:ok, role} =
      Roles.create(%{
        name: "Role #{System.unique_integer([:positive])}",
        position: 100,
        permissions: Roles.mask(~w(manage_users manage_reports))
      })

    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, _assigned} = Roles.assign(user, role)

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, scopes)

    raw
  end

  describe "a token that only asked to read" do
    test "cannot post", %{conn: conn} do
      {_account, raw} = token(["read"])

      body =
        conn
        |> as(raw)
        |> post(~p"/api/v1/statuses", %{"status" => "hello"})
        |> json_response(403)

      # Naming what was missing is the difference between a developer fixing
      # their scope list in a minute and filing a bug about a broken endpoint.
      assert body["required_scopes"] == ["write:statuses"]
    end

    test "cannot follow, block or mute", %{conn: conn} do
      {_account, raw} = token(["read"])
      other = account_fixture()

      assert json_response(post(as(conn, raw), ~p"/api/v1/accounts/#{other.id}/follow"), 403)
      assert json_response(post(as(conn, raw), ~p"/api/v1/accounts/#{other.id}/block"), 403)
      assert json_response(post(as(conn, raw), ~p"/api/v1/accounts/#{other.id}/mute"), 403)
    end

    test "still reads", %{conn: conn} do
      {account, raw} = token(["read"])

      # The positive control. Without it every refusal above would pass against
      # a server that had simply stopped answering.
      assert json_response(get(as(conn, raw), ~p"/api/v1/accounts/verify_credentials"), 200)[
               "id"
             ] == to_string(account.id)
    end
  end

  describe "a token that asked for the right thing" do
    test "posts", %{conn: conn} do
      {_account, raw} = token(["read", "write:statuses"])

      assert json_response(
               post(as(conn, raw), ~p"/api/v1/statuses", %{"status" => "hello"}),
               200
             )["content"] =~ "hello"
    end

    test "follows", %{conn: conn} do
      {_account, raw} = token(["write:follows"])
      other = account_fixture()

      assert json_response(post(as(conn, raw), ~p"/api/v1/accounts/#{other.id}/follow"), 200)
    end
  end

  describe "the narrower scopes" do
    test "a write:statuses token cannot read somebody's bookmarks", %{conn: conn} do
      {_account, raw} = token(["write:statuses"])

      assert json_response(get(as(conn, raw), ~p"/api/v1/bookmarks"), 403)
    end

    test "a read:bookmarks token can", %{conn: conn} do
      {_account, raw} = token(["read:bookmarks", "write:bookmarks"])
      status = status_fixture(%{account_id: account_fixture().id, text: "worth keeping"})

      assert json_response(post(as(conn, raw), ~p"/api/v1/statuses/#{status.id}/bookmark"), 200)

      assert [%{"id" => id}] = json_response(get(as(conn, raw), ~p"/api/v1/bookmarks"), 200)
      assert id == to_string(status.id)
    end
  end

  describe "the scopes an app can actually be granted" do
    test "a profile-only token reads a profile and nothing else", %{conn: conn} do
      # `profile` exists so an app can ask for a name and a picture without
      # asking to read everything. Refusing it here would make the scope
      # useless, which is what requiring `read:accounts` outright did.
      {_account, raw} = token(["profile"])

      assert json_response(get(as(conn, raw), ~p"/api/v1/accounts/verify_credentials"), 200)
      assert json_response(get(as(conn, raw), ~p"/api/v1/bookmarks"), 403)
    end

    test "a narrow admin scope satisfies the endpoint it names", %{conn: conn} do
      raw = moderator_token(["admin:read:accounts"])

      assert json_response(get(as(conn, raw), ~p"/api/v1/admin/accounts"), 200)

      # And only the one it names. Advertising `admin:read:reports` while every
      # endpoint asked for the umbrella would have made the narrow scopes a
      # decoration.
      assert json_response(get(as(conn, raw), ~p"/api/v1/admin/reports"), 403)
    end
  end

  describe "the scopes outside the read and write families" do
    test "push notifications want the push scope", %{conn: conn} do
      {_account, raw} = token(["read", "write"])

      assert json_response(get(as(conn, raw), ~p"/api/v1/push/subscription"), 403)[
               "required_scopes"
             ] == ["push"]

      {_account, pushable} = token(["push"])
      assert get(as(conn, pushable), ~p"/api/v1/push/subscription").status in [200, 404]
    end

    test "an upload is not something a posting scope covers", %{conn: conn} do
      {_account, raw} = token(["write:statuses"])

      assert json_response(get(as(conn, raw), ~p"/api/v1/media/1"), 403)["required_scopes"] ==
               ["write:media"]
    end
  end

  describe "reads a token widens" do
    test "a write-only token cannot read a private post through any of them", %{conn: conn} do
      {account, raw} = token(["write:statuses"])

      status =
        status_fixture(%{
          account_id: account.id,
          text: "just for followers",
          visibility: :private
        })

      for path <- [
            ~p"/api/v1/statuses/#{status.id}",
            ~p"/api/v1/statuses/#{status.id}/context",
            ~p"/api/v1/accounts/#{account.id}/statuses",
            ~p"/api/v1/timelines/public"
          ] do
        assert json_response(get(as(conn, raw), path), 403)["required_scopes"]
      end
    end

    test "a read token still sees it", %{conn: conn} do
      {account, raw} = token(["read:statuses", "read:accounts"])

      status =
        status_fixture(%{
          account_id: account.id,
          text: "just for followers",
          visibility: :private
        })

      assert json_response(get(as(conn, raw), ~p"/api/v1/statuses/#{status.id}"), 200)["content"] =~
               "followers"
    end
  end

  describe "the admin surface" do
    test "refuses a moderator whose app never asked for admin", %{conn: conn} do
      # The role says who this person is allowed to be; the scope says what the
      # app they authorised was allowed to ask for. A leaked token turns on the
      # second, so being a moderator is not on its own enough.
      raw = moderator_token(["read", "write"])

      body = json_response(get(as(conn, raw), ~p"/api/v1/admin/accounts"), 403)

      assert body["required_scopes"] == ["admin:read", "admin:read:accounts"]
    end

    test "lets the same moderator through with an admin token", %{conn: conn} do
      raw = moderator_token(["read", "write", "admin:read"])

      assert json_response(get(as(conn, raw), ~p"/api/v1/admin/accounts"), 200)
    end

    test "an admin:read token still cannot act", %{conn: conn} do
      raw = moderator_token(["read", "write", "admin:read"])
      other = account_fixture()

      body =
        json_response(post(as(conn, raw), ~p"/api/v1/admin/accounts/#{other.id}/action"), 403)

      assert body["required_scopes"] == ["admin:write", "admin:write:accounts"]
    end
  end

  describe "an endpoint that answers a stranger" do
    test "still answers one, with no token at all", %{conn: conn} do
      account_fixture(%{username: "findme"})

      assert json_response(get(conn, ~p"/api/v2/search", %{"q" => "findme"}), 200)
    end

    test "refuses a token whose app never asked to search", %{conn: conn} do
      {_account, raw} = token(["write:statuses"])

      assert json_response(get(as(conn, raw), ~p"/api/v2/search", %{"q" => "findme"}), 403)
    end

    test "keeps answering the reads that never needed a token", %{conn: conn} do
      status = status_fixture(%{account_id: account_fixture().id, text: "in public"})

      # Declaring a scope on a public read would have turned every one of these
      # into a 401 for the readers they exist for.
      assert json_response(get(conn, ~p"/api/v1/statuses", %{"id" => [status.id]}), 200)
      assert json_response(get(conn, ~p"/api/v1/statuses/#{status.id}/history"), 200)
    end

    test "asks a stranger to sign in rather than answering 500", %{conn: conn} do
      status = status_fixture(%{account_id: account_fixture().id, text: "mine"})

      # These compare a post's owner against the signed-in account, which
      # anonymously was nil, so the comparison raised on a public post.
      assert json_response(get(conn, ~p"/api/v1/statuses/#{status.id}/source"), 422)

      assert json_response(
               put(conn, ~p"/api/v1/statuses/#{status.id}/interaction_policy", %{}),
               422
             )

      assert json_response(
               post(conn, ~p"/api/v1/statuses/#{status.id}/quotes/#{status.id}/revoke"),
               422
             )
    end
  end
end
