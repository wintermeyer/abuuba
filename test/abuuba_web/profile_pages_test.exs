defmodule AbuubaWeb.ProfilePagesTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Statuses

  setup do
    subject = account_fixture(%{username: "alice", display_name: "Alice"})
    follower = account_fixture(%{username: "bob"})
    followee = account_fixture(%{username: "carol"})

    Relationships.follow(follower, subject)
    Relationships.follow(subject, followee)

    %{subject: subject, follower: follower, followee: followee}
  end

  describe "the followers and following pages" do
    test "list who follows and who is followed", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/@alice/followers")
      assert html =~ "bob"

      {:ok, _live, html} = live(conn, ~p"/@alice/following")
      assert html =~ "carol"
    end

    test "are reachable from the profile", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/@alice")

      assert html =~ ~p"/@alice/followers"
      assert html =~ ~p"/@alice/following"
    end

    test "say nothing when the account hides them", %{conn: conn, subject: subject} do
      subject |> Ecto.Changeset.change(hide_collections: true) |> Repo.update!()

      {:ok, _live, html} = live(conn, ~p"/@alice/followers")

      # Three characters against a page that carries fresh base64 on every
      # request; see `page/1`.
      refute page(html) =~ "bob"
      assert html =~ "keeps its follows to itself"
    end

    test "still show them to their owner", %{conn: conn, subject: subject} do
      subject |> Ecto.Changeset.change(hide_collections: true) |> Repo.update!()

      user =
        user_fixture(%{account_id: subject.id, approved: true, confirmed_at: DateTime.utc_now()})

      # A setting that hid the lists from the person who set it would look like
      # a bug the first time they checked it worked.
      {:ok, _live, html} = conn |> log_in(user) |> live(~p"/@alice/followers")

      assert html =~ "bob"
    end
  end

  describe "the profile feed" do
    setup %{subject: subject} do
      status_fixture(%{account_id: subject.id, text: "<p>a public thing</p>"})

      :ok
    end

    test "is served as RSS at the address readers know", %{conn: conn} do
      conn = get(conn, "/@alice.rss")

      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "application/rss+xml"

      body = response(conn, 200)
      assert body =~ "<rss"
      assert body =~ "a public thing"
      assert body =~ "Alice"
    end

    test "leaves out anything that is not public", %{conn: conn, subject: subject} do
      status_fixture(%{
        account_id: subject.id,
        text: "<p>only for followers</p>",
        visibility: "private"
      })

      status_fixture(%{
        account_id: subject.id,
        text: "<p>quietly</p>",
        visibility: "unlisted"
      })

      body = conn |> get("/@alice.rss") |> response(200)

      # A feed is one of the lists this server publishes, and unlisted means
      # exactly "not in those".
      assert body =~ "a public thing"
      refute body =~ "only for followers"
      refute body =~ "quietly"
    end

    test "leaves out boosts", %{conn: conn, subject: subject} do
      other = status_fixture(%{account_id: account_fixture().id, text: "<p>somebody else</p>"})
      Statuses.boost(subject, other)

      refute conn |> get("/@alice.rss") |> response(200) =~ "somebody else"
    end

    test "puts a content warning in the title", %{conn: conn, subject: subject} do
      status_fixture(%{
        account_id: subject.id,
        text: "<p>the ending</p>",
        spoiler_text: "spoilers"
      })

      # A reader's list view should carry the warning rather than the thing it
      # was warning about.
      assert conn |> get("/@alice.rss") |> response(200) =~ "<title>spoilers</title>"
    end

    test "cannot be closed early by something in a post", %{conn: conn, subject: subject} do
      status_fixture(%{account_id: subject.id, text: "<p>look: ]]> &lt;/rss&gt;</p>"})

      body = conn |> get("/@alice.rss") |> response(200)

      refute body =~ "]]>" <> " &lt;/rss&gt;"
      assert body =~ "]]&gt;"
    end

    test "404s for somebody who is not here", %{conn: conn} do
      assert_raise AbuubaWeb.NotFound, fn -> get(conn, "/@nobody.rss") end
    end
  end

  describe "the hashtag feed" do
    test "carries what is tagged", %{conn: conn, subject: subject} do
      status_fixture(%{account_id: subject.id, text: "<p>about #gardening</p>"})

      body = conn |> get("/tags/gardening.rss") |> response(200)

      assert body =~ "<rss"
      assert body =~ "about"
      assert body =~ "#gardening"
    end

    test "is empty rather than an error for a tag nobody used", %{conn: conn} do
      assert conn |> get("/tags/nothingatall.rss") |> response(200) =~ "<rss"
    end
  end

  describe "the rewrite" do
    test "leaves an ordinary profile alone", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/@alice")

      assert html =~ "Alice"
    end

    test "leaves a tag page alone", %{conn: conn} do
      {:ok, _live, _html} = live(conn, ~p"/tags/gardening")
    end
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end
end
