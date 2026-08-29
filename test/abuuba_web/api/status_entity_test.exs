defmodule AbuubaWeb.API.StatusEntityTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.PostingDefaults
  alias Abuuba.Filters
  alias Abuuba.OAuth
  alias Abuuba.Repo

  setup %{conn: conn} do
    account = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{
        name: "Ivory",
        website: "https://ivory.example",
        redirect_uris: "urn:ietf:wg:oauth:2.0:oob"
      })

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> raw),
      anon: build_conn(),
      account: account,
      user: user,
      application: application
    }
  end

  defp posted(conn, text \\ "hello") do
    json_response(post(conn, "/api/v1/statuses", %{"status" => text}), 200)
  end

  describe "which app a post was written in" do
    test "is recorded and reported", %{conn: conn} do
      created = posted(conn)

      assert created["application"] == %{
               "name" => "Ivory",
               "website" => "https://ivory.example"
             }

      # And on the way back out, not only in the answer to the write.
      assert json_response(get(conn, "/api/v1/statuses/#{created["id"]}"), 200)["application"] ==
               created["application"]
    end

    test "a website nobody set is null rather than an empty string", %{user: user} do
      {:ok, bare, _secret} =
        OAuth.create_application(%{name: "Bare", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

      {:ok, _token, raw} = OAuth.issue_token(bare, user, ["read", "write"])

      created =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> posted()

      assert created["application"] == %{"name" => "Bare", "website" => nil}
    end

    test "a stranger sees it too, by default", %{conn: conn, anon: anon} do
      created = posted(conn)

      assert %{"name" => "Ivory"} =
               json_response(get(anon, "/api/v1/statuses/#{created["id"]}"), 200)["application"]
    end

    test "somebody who turned it off hides it from everybody but themselves", %{
      conn: conn,
      anon: anon,
      user: user
    } do
      created = posted(conn)

      {:ok, _user} =
        Accounts.update_user_settings(
          user,
          PostingDefaults.merge(user.settings, %{"show_application" => "false"})
        )

      assert json_response(get(anon, "/api/v1/statuses/#{created["id"]}"), 200)["application"] ==
               nil

      # Their own posts still say it. Turning it off is about what other people
      # see, not about forgetting which app you wrote something in.
      assert %{"name" => "Ivory"} =
               json_response(get(conn, "/api/v1/statuses/#{created["id"]}"), 200)["application"]
    end

    test "a post from another server has none", %{anon: anon} do
      remote = remote_account_fixture()
      status = status_fixture(%{account_id: remote.id, local: false})

      assert json_response(get(anon, "/api/v1/statuses/#{status.id}"), 200)["application"] == nil
    end

    test "one written before this existed has none, and does not break", %{
      conn: conn,
      account: account
    } do
      status = status_fixture(%{account_id: account.id})

      assert json_response(get(conn, "/api/v1/statuses/#{status.id}"), 200)["application"] == nil
    end
  end

  describe "which of the reader's filters matched" do
    setup %{account: account} do
      {:ok, filter} =
        Filters.create(account, %{
          "title" => "Spoilers",
          "context" => ["home"],
          "keywords_attributes" => [%{"keyword" => "finale"}]
        })

      author = account_fixture()
      {:ok, _} = Abuuba.Relationships.follow(account, author)

      %{filter: filter, author: author}
    end

    test "comes back on the timeline the filter applies to", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "the finale was something"})

      assert [rendered] = json_response(get(conn, "/api/v1/timelines/home"), 200)

      assert [%{"filter" => %{"title" => "Spoilers"}}] = rendered["filtered"]
    end

    test "is empty rather than absent where nothing matched", %{conn: conn, author: author} do
      # A client reads the key and folds nothing away; absent would make it
      # guess, and guessing wrong hides a post nobody asked to hide.
      status_fixture(%{account_id: author.id, text: "an ordinary morning"})

      assert [rendered] = json_response(get(conn, "/api/v1/timelines/home"), 200)
      assert rendered["filtered"] == []
    end

    test "does not apply a home filter to a public timeline", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "the finale was something"})

      assert [rendered] = json_response(get(conn, "/api/v1/timelines/public"), 200)
      assert rendered["filtered"] == []
    end

    test "is absent for a reader nobody knows", %{conn: conn, anon: anon, author: author} do
      status = status_fixture(%{account_id: author.id, text: "the finale was something"})

      refute Map.has_key?(
               json_response(get(anon, "/api/v1/statuses/#{status.id}"), 200),
               "filtered"
             )

      # And absent from a single post, which has no context of its own to
      # decide with, even for somebody signed in.
      refute Map.has_key?(
               json_response(get(conn, "/api/v1/statuses/#{status.id}"), 200),
               "filtered"
             )
    end

    test "a thread says so, because a filter can name that context", %{
      conn: conn,
      account: account,
      author: author,
      filter: filter
    } do
      {:ok, _} = Filters.update(filter, %{"context" => ["thread"]})

      root = status_fixture(%{account_id: account.id, text: "start"})

      status_fixture(%{
        account_id: author.id,
        text: "about the finale",
        in_reply_to_id: root.id,
        in_reply_to_account_id: account.id
      })

      body = json_response(get(conn, "/api/v1/statuses/#{root.id}/context"), 200)

      assert [reply] = body["descendants"]
      assert [%{"filter" => %{"title" => "Spoilers"}}] = reply["filtered"]
    end
  end

  describe "the setting" do
    test "reads back and saves", %{conn: conn, user: user} do
      assert PostingDefaults.for_user(user)["show_application"] == true

      {:ok, updated} =
        Accounts.update_user_settings(
          user,
          PostingDefaults.merge(user.settings, %{"show_application" => "false"})
        )

      assert PostingDefaults.for_user(Repo.reload!(updated))["show_application"] == false
      assert json_response(get(conn, "/api/v1/preferences"), 200)
    end
  end
end
