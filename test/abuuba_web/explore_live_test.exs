defmodule AbuubaWeb.ExploreLiveTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Auth
  alias Abuuba.Statuses

  setup %{conn: conn} do
    author = account_fixture(%{username: "bob", display_name: "Bob", discoverable: true})

    reader = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

    %{conn: conn, signed_in: log_in(conn, user), author: author, reader: reader}
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  describe "the page" do
    test "is rendered by the server, for somebody who is not signed in", %{
      conn: conn,
      author: author
    } do
      status_fixture(%{account_id: author.id, text: "something public"})

      html = conn |> get(~p"/explore") |> html_response(200)

      assert html =~ "something public"
    end

    test "each tab is its own address", %{conn: conn} do
      for path <- [~p"/explore", ~p"/explore/tags", ~p"/explore/people"] do
        assert conn |> get(path) |> html_response(200)
      end
    end

    test "the tab in the address is the one marked current", %{conn: conn} do
      html = conn |> get(~p"/explore/tags") |> html_response(200)

      assert html =~ ~s(aria-current="page")
    end
  end

  describe "posts" do
    test "shows public posts and not private ones", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "for everybody"})
      status_fixture(%{account_id: author.id, text: "for followers", visibility: :private})

      html = conn |> get(~p"/explore") |> html_response(200)

      assert html =~ "for everybody"
      refute html =~ "for followers"
    end

    test "says so when there is nothing yet", %{conn: conn} do
      html = conn |> get(~p"/explore") |> html_response(200)

      assert html =~ "Nothing"
    end
  end

  describe "hashtags" do
    test "lists tags that posts are actually using", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "about #gardening"})

      html = conn |> get(~p"/explore/tags") |> html_response(200)

      assert html =~ "gardening"
    end

    test "leaves out a tag a moderator has hidden", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "about #hidden"})
      tag = Statuses.get_tag("hidden")
      {:ok, _} = tag |> Ecto.Changeset.change(listable: false) |> Abuuba.Repo.update()

      html = conn |> get(~p"/explore/tags") |> html_response(200)

      refute html =~ ~s(href="/tags/hidden")
    end

    test "a tag links to its own page", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "about #gardening"})

      html = conn |> get(~p"/explore/tags") |> html_response(200)

      assert html =~ ~s(href="/tags/gardening")
    end
  end

  describe "the local directory" do
    test "lists people who asked to be listed", %{conn: conn} do
      html = conn |> get(~p"/explore/people") |> html_response(200)

      assert html =~ "Bob"
    end

    test "leaves out somebody who did not", %{conn: conn} do
      # Being findable is a choice, and the default is no.
      account_fixture(%{username: "quiet", display_name: "Quiet One", discoverable: false})

      html = conn |> get(~p"/explore/people") |> html_response(200)

      refute html =~ "Quiet One"
    end

    test "leaves out somebody suspended", %{conn: conn, author: author} do
      {:ok, _} =
        author |> Ecto.Changeset.change(suspended_at: DateTime.utc_now()) |> Abuuba.Repo.update()

      html = conn |> get(~p"/explore/people") |> html_response(200)

      # Through `page/1`, which takes the signed blobs out. This refute is
      # three characters long and the page carries ~166 bytes of fresh base64
      # on every request, so it matched a random `csrf-token` about once in
      # 641 runs -- which is what the two failures were, and why neither could
      # ever be reproduced.
      refute page(html) =~ "Bob", """
      the suspended account is still on the page. Found around:

      #{context_around(html, "Bob")}
      """
    end

    test "a card links to the profile", %{conn: conn} do
      html = conn |> get(~p"/explore/people") |> html_response(200)

      assert html =~ ~s(href="/@bob")
    end

    test "somebody signed in can follow from here", %{
      signed_in: conn,
      author: author,
      reader: reader
    } do
      {:ok, live, _html} = live(conn, ~p"/explore/people")

      live
      |> element("button[phx-value-account='#{author.id}'][phx-click='follow']")
      |> render_click()

      assert Abuuba.Relationships.following?(reader, author)
    end

    test "somebody who approves their followers is asked, not followed", %{
      signed_in: conn,
      author: author,
      reader: reader
    } do
      {:ok, locked} = Accounts.update_account(author, %{locked: true})

      {:ok, live, _html} = live(conn, ~p"/explore/people")

      html =
        live
        |> element("button[phx-value-account='#{locked.id}'][phx-click='follow']")
        |> render_click()

      refute Abuuba.Relationships.following?(reader, locked),
             "the card followed a locked account outright instead of asking it"

      assert Abuuba.Relationships.get_follow_request(reader, locked)
      assert html =~ "Requested"
    end

    test "a passer-by is offered nothing to press", %{conn: conn} do
      html = conn |> get(~p"/explore/people") |> html_response(200)

      refute html =~ ~s(phx-click="follow")
    end
  end

  describe "a tag's own page" do
    test "shows the posts filed under it", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "about #gardening"})
      status_fixture(%{account_id: author.id, text: "about #cooking"})

      html = conn |> get(~p"/tags/gardening") |> html_response(200)

      assert html =~ "about"
      assert html =~ ~s(/tags/gardening")
      refute html =~ ~s(/tags/cooking")
    end

    test "the case somebody typed does not matter", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "about #gardening"})

      html = conn |> get("/tags/Gardening") |> html_response(200)

      assert html =~ ~s(/tags/gardening")
    end

    test "a tag nobody has used is a page rather than a miss", %{conn: conn} do
      # A hashtag in somebody's post is a link, and a link that 404s reads as a
      # broken post rather than an empty tag.
      html = conn |> get(~p"/tags/nobodyhasusedthis") |> html_response(200)

      assert html =~ "nobodyhasusedthis"
    end

    test "somebody signed in can follow the tag", %{signed_in: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "about #gardening"})

      {:ok, live, _html} = live(conn, ~p"/tags/gardening")

      live |> element("button[phx-click='follow_tag']") |> render_click()

      reader = Accounts.get_account_by_handle("alice", nil)
      assert Statuses.following_tag?(reader, Statuses.get_tag("gardening"))
    end
  end

  describe "what is trending" do
    test "comes before the rest", %{conn: conn} do
      author = account_fixture()
      {:ok, author} = Abuuba.Accounts.update_profile(author, %{"discoverable" => true})

      {:ok, hot} = Abuuba.Statuses.upsert_tag("hot")
      {:ok, _cold} = Abuuba.Statuses.upsert_tag("cold")
      :ok = Abuuba.Trends.approve(account_fixture(), "tag", hot.name)
      Abuuba.Trends.put_counts("tag", "hot", Date.utc_today(), accounts: 40)
      :ok = Abuuba.Trends.rank()

      {:ok, _live, html} = live(conn, ~p"/explore/tags")

      assert html =~ "hot"
      # The trending one is listed first; the rest of the tab follows it.
      assert :binary.match(html, "hot") < :binary.match(html, "cold")
      refute author == nil
    end

    test "and nothing is called trending before it has been reviewed", %{conn: conn} do
      {:ok, _} = Abuuba.Statuses.upsert_tag("unseen")
      Abuuba.Trends.put_counts("tag", "unseen", Date.utc_today(), accounts: 40)
      :ok = Abuuba.Trends.rank()

      {:ok, _live, _html} = live(conn, ~p"/explore/tags")

      assert Abuuba.Trends.list("tag") == []
    end
  end

  # A window of the markup either side of the first match, for a refutation
  # that fails against a whole rendered page.
  defp context_around(html, needle) do
    case :binary.match(html, needle) do
      {at, _length} ->
        from = max(at - 200, 0)

        binary_part(html, from, min(400, byte_size(html) - from))

      :nomatch ->
        "(not found, which means this assertion passed)"
    end
  end
end
