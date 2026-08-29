defmodule AbuubaWeb.SearchLiveTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth

  setup %{conn: conn} do
    author = account_fixture(%{username: "bob", display_name: "Bob Gardener"})
    reader = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

    status_fixture(%{account_id: author.id, text: "notes on gardening"})

    %{conn: conn, signed_in: log_in(conn, user), author: author}
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  describe "the page" do
    test "opens empty, with the box ready", %{conn: conn} do
      html = conn |> get(~p"/search") |> html_response(200)

      assert html =~ ~s(name="q")
    end

    test "says what the box can do", %{conn: conn} do
      # An interface that hides its operators is one where only the people who
      # read the source know they exist.
      html = conn |> get(~p"/search") |> html_response(200)

      for operator <- Abuuba.Search.operators() do
        assert html =~ operator.name
      end
    end
  end

  describe "results" do
    test "finds people, tags and posts in one query", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "more #gardening"})

      html = conn |> get(~p"/search?q=gardening") |> html_response(200)

      assert html =~ "notes on gardening"
      assert html =~ "#gardening"
    end

    test "finds an account by name", %{conn: conn} do
      html = conn |> get(~p"/search?q=bob") |> html_response(200)

      assert html =~ "Bob Gardener"
    end

    test "says so when nothing matches", %{conn: conn} do
      html = conn |> get(~p"/search?q=zzzznothing") |> html_response(200)

      assert html =~ "Nothing matched"
    end

    test "keeps a private post away from a stranger", %{conn: conn, author: author} do
      status_fixture(%{
        account_id: author.id,
        text: "a quiet gardening note",
        visibility: :private
      })

      html = conn |> get(~p"/search?q=quiet") |> html_response(200)

      refute html =~ "a quiet gardening note"
    end
  end

  describe "deep links" do
    test "type=accounts shows only people", %{conn: conn} do
      html = conn |> get(~p"/search?q=gardening&type=accounts") |> html_response(200)

      refute html =~ "notes on gardening"
    end

    test "type=statuses shows only posts", %{conn: conn} do
      html = conn |> get(~p"/search?q=bob&type=statuses") |> html_response(200)

      refute html =~ "Bob Gardener"
    end

    test "the type in the address is the one marked current", %{conn: conn} do
      html = conn |> get(~p"/search?q=gardening&type=hashtags") |> html_response(200)

      assert html =~ ~s(aria-current="page")
    end

    test "a type nobody defined falls back to everything", %{conn: conn} do
      html = conn |> get("/search?q=gardening&type=nonsense") |> html_response(200)

      assert html =~ "notes on gardening"
    end
  end

  describe "operators" do
    test "from: narrows to one author", %{conn: conn, author: author} do
      other = account_fixture(%{username: "carol"})
      status_fixture(%{account_id: other.id, text: "carol on gardening"})

      html = conn |> get("/search?q=from%3Abob+gardening") |> html_response(200)

      assert html =~ "notes on gardening"
      refute html =~ "carol on gardening"
      assert author.username == "bob"
    end

    test "an operator does not stop tags being found", %{conn: conn, author: author} do
      # The operators narrow posts. Searching the raw string for a tag looks
      # for "from:bob gardening" and finds nothing, so a query with an operator
      # in it would silently lose two of the three sections.
      status_fixture(%{account_id: author.id, text: "more #gardening"})

      html = conn |> get("/search?q=from%3Abob+gardening&type=hashtags") |> html_response(200)

      assert html =~ ~s(href="/tags/gardening")
    end

    test "an operator does not stop people being found", %{conn: conn} do
      html = conn |> get("/search?q=has%3Amedia+bob&type=accounts") |> html_response(200)

      assert html =~ "Bob Gardener"
    end

    test "searching from the box keeps the query in the address", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/search")

      live |> form("#search-form", %{"q" => "gardening"}) |> render_submit()

      assert_patched(live, ~p"/search?q=gardening")
    end
  end
end
