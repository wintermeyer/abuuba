defmodule Abuuba.Security.VisibilityTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.OAuth
  alias Abuuba.Relationships
  alias Abuuba.Statuses

  # The authorisation matrix. Every one of these is a way a private post has
  # leaked out of a fediverse server before: not through the timeline it was
  # written for, but through search, an embed, a boost, a context, or an
  # unauthenticated read of the same id.

  setup %{conn: conn} do
    author = account_fixture()
    follower = account_fixture()
    stranger = account_fixture()

    {:ok, _follow} = Relationships.follow(follower, author)

    posts =
      Map.new([:public, :unlisted, :private, :direct], fn visibility ->
        {visibility,
         status_fixture(%{
           account_id: author.id,
           text: "#{visibility} secret",
           visibility: visibility
         })}
      end)

    %{conn: conn, author: author, follower: follower, stranger: stranger, posts: posts}
  end

  # A real bearer token, because that is what the API reads. A session cookie
  # is not authentication here, and a test that used one would pass every
  # "cannot read this" assertion for the wrong reason — which is worse than no
  # test at all, and is exactly what happened to the first draft of this file.
  defp as(_conn, account) do
    user =
      user_fixture(%{account_id: account.id, confirmed_at: DateTime.utc_now(), approved: true})

    {:ok, application, _secret} =
      OAuth.create_application(%{
        name: "security-test-#{System.unique_integer([:positive])}",
        redirect_uris: "urn:ietf:wg:oauth:2.0:oob"
      })

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    put_req_header(build_conn(), "authorization", "Bearer " <> raw)
  end

  describe "a stranger, signed in" do
    test "cannot read a private post by its id", %{conn: conn, stranger: stranger, posts: posts} do
      # The single most direct way in: knowing the number.
      conn = conn |> as(stranger) |> get(~p"/api/v1/statuses/#{posts.private.id}")

      assert conn.status == 404
    end

    test "nor a direct one", %{conn: conn, stranger: stranger, posts: posts} do
      conn = conn |> as(stranger) |> get(~p"/api/v1/statuses/#{posts.direct.id}")

      assert conn.status == 404
    end

    test "and does not find them by searching for their words", %{
      conn: conn,
      stranger: stranger
    } do
      # Search reads a different path from the timeline, and it is the path
      # that has leaked in other servers.
      conn = conn |> as(stranger) |> get(~p"/api/v2/search?q=secret&type=statuses")

      body = json_response(conn, 200)

      refute Enum.any?(body["statuses"], &(&1["content"] =~ "private secret"))
      refute Enum.any?(body["statuses"], &(&1["content"] =~ "direct secret"))
    end

    test "and does not see them in the author's own statuses", %{
      conn: conn,
      stranger: stranger,
      author: author
    } do
      conn = conn |> as(stranger) |> get(~p"/api/v1/accounts/#{author.id}/statuses")

      contents = conn |> json_response(200) |> Enum.map_join(" ", & &1["content"])

      refute contents =~ "private secret"
      refute contents =~ "direct secret"
    end

    test "and cannot reach one through a thread", %{
      conn: conn,
      stranger: stranger,
      author: author,
      posts: posts
    } do
      # A context is a read of other people's posts by definition, so it is
      # exactly where a visibility check gets forgotten.
      reply =
        status_fixture(%{
          account_id: author.id,
          text: "public reply",
          visibility: :public,
          in_reply_to_id: posts.private.id
        })

      conn = conn |> as(stranger) |> get(~p"/api/v1/statuses/#{reply.id}/context")

      body = json_response(conn, 200)

      refute Enum.any?(body["ancestors"], &(&1["content"] =~ "private secret"))
    end
  end

  describe "a follower" do
    test "reads a followers-only post", %{conn: conn, follower: follower, posts: posts} do
      # The other half of the matrix: a check that refuses everybody is not a
      # working check.
      conn = conn |> as(follower) |> get(~p"/api/v1/statuses/#{posts.private.id}")

      assert json_response(conn, 200)["content"] =~ "private secret"
    end

    test "but still not a direct one they were not sent", %{
      conn: conn,
      follower: follower,
      posts: posts
    } do
      conn = conn |> as(follower) |> get(~p"/api/v1/statuses/#{posts.direct.id}")

      assert conn.status == 404
    end
  end

  describe "nobody at all" do
    test "reads only what was published in the open", %{conn: conn, posts: posts} do
      assert conn |> get(~p"/api/v1/statuses/#{posts.public.id}") |> json_response(200)

      for visibility <- [:private, :direct] do
        assert build_conn()
               |> get(~p"/api/v1/statuses/#{posts[visibility].id}")
               |> Map.get(:status) == 404
      end
    end

    test "and the public timeline holds nothing else", %{conn: conn} do
      # Unlisted is deliberately absent too: it is readable by address and not
      # by browsing, which is the whole difference between it and public.
      contents =
        conn
        |> get(~p"/api/v1/timelines/public")
        |> json_response(200)
        |> Enum.map_join(" ", & &1["content"])

      refute contents =~ "private secret"
      refute contents =~ "direct secret"
      refute contents =~ "unlisted secret"
    end
  end

  describe "boosting" do
    test "does not make a followers-only post public", %{
      conn: conn,
      follower: follower,
      stranger: stranger,
      posts: posts
    } do
      # A boost is a second door onto the same post. If it carried its own
      # visibility, anybody who could read a private post could publish it.
      {:ok, _boost} = Statuses.boost(follower, posts.private)

      conn = conn |> as(stranger) |> get(~p"/api/v1/statuses/#{posts.private.id}")

      assert conn.status == 404
    end
  end
end
