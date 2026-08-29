defmodule AbuubaWeb.StatusLiveTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Federation.URIs
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Favourite
  alias Abuuba.Translation
  alias Abuuba.Translation.Fake

  setup %{conn: conn} do
    author = account_fixture(%{username: "bob", display_name: "Bob"})
    reader = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

    root = status_fixture(%{account_id: author.id, text: "the first post"})

    %{
      conn: conn,
      signed_in: log_in(conn, user),
      author: author,
      reader: reader,
      root: root
    }
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  defp at(status, author), do: "/@#{author.username}/#{status.id}"

  describe "a post on its own page" do
    test "is rendered by the server, before any socket connects", %{
      conn: conn,
      root: root,
      author: author
    } do
      # The point of the page: somebody following a link, and every link
      # preview, gets real HTML rather than a shell to fill in later.
      html = conn |> get(at(root, author)) |> html_response(200)

      assert html =~ "the first post"
      assert html =~ "Bob"
    end

    test "keeps crawlers off until its author asks them in", %{
      conn: conn,
      root: root,
      author: author
    } do
      html = conn |> get(at(root, author)) |> html_response(200)
      assert html =~ "noindex, noarchive"

      {:ok, author} = Abuuba.Accounts.update_account(author, %{indexable: true})

      html = conn |> get(at(root, author)) |> html_response(200)
      refute html =~ "noindex"
      # The positive control: the page is still the page, so the refute above
      # is not passing on an error template.
      assert html =~ "the first post"
    end

    test "carries what a link preview reads", %{conn: conn, root: root, author: author} do
      html = conn |> get(at(root, author)) |> html_response(200)

      assert html =~ ~s(property="og:title")
      assert html =~ ~s(property="og:description")
      assert html =~ ~s(property="og:type")
      assert html =~ "the first post"
    end

    test "points a preview at the page rather than at the document behind it", %{
      conn: conn,
      root: root,
      author: author
    } do
      # A preview's canonical address is the page a reader lands on. The post's
      # ActivityPub id is a JSON document and is nobody's destination.
      html = conn |> get(at(root, author)) |> html_response(200)

      assert html =~ ~s(content="#{URIs.base_url()}#{at(root, author)}")
    end

    test "keeps a preview's text on one line", %{conn: conn, author: author} do
      # A newline inside a meta tag's content is what turns a tidy preview into
      # a broken one, and it costs nothing to take out.
      multiline = status_fixture(%{account_id: author.id, text: "first line\n\nsecond line"})

      html = conn |> get(at(multiline, author)) |> html_response(200)

      assert html =~ "first line second line"
    end

    test "says what it is in the title", %{conn: conn, root: root, author: author} do
      html = conn |> get(at(root, author)) |> html_response(200)

      assert html =~ "Bob"
    end

    test "a post nobody has is a plain miss", %{conn: conn, author: author} do
      assert_error_sent 404, fn -> get(conn, "/@#{author.username}/999999999999") end
    end

    test "a post under the wrong name is a miss", %{conn: conn, root: root} do
      # The handle in the path is part of the address, not decoration.
      assert_error_sent 404, fn -> get(conn, "/@nobody/#{root.id}") end
    end
  end

  describe "a poll on a post" do
    test "counts answers and people, which are not the same number", %{
      conn: conn,
      author: author
    } do
      # The user guide says a poll shows two numbers and explains why they
      # differ on a poll that takes more than one answer. Only one of them was
      # on the screen, so the page a reader was sent to did not show what the
      # page they read said it would.
      {:ok, status} =
        Statuses.create_status(
          %{"account_id" => author.id, "text" => "pick any"},
          poll: %{"options" => ["tea", "coffee"], "expires_in" => 3600, "multiple" => true}
        )

      poll = Statuses.get_poll(status)

      {:ok, _} =
        poll
        |> Ecto.Changeset.change(tallies: [3, 2], voters_count: 3)
        |> Repo.update()

      {:ok, _view, html} = live(conn, ~p"/@bob/#{status.id}")

      assert html =~ "5 votes"
      assert html =~ "3 people"
    end

    test "and says people only where the two can differ", %{conn: conn, author: author} do
      # One answer each, so the second number would be the first written twice.
      {:ok, status} =
        Statuses.create_status(
          %{"account_id" => author.id, "text" => "pick one"},
          poll: %{"options" => ["tea", "coffee"], "expires_in" => 3600, "multiple" => false}
        )

      poll = Statuses.get_poll(status)

      {:ok, _} =
        poll |> Ecto.Changeset.change(tallies: [2, 1], voters_count: 3) |> Repo.update()

      {:ok, _view, html} = live(conn, ~p"/@bob/#{status.id}")

      assert html =~ "3 votes"
      refute html =~ "people"
    end
  end

  describe "the thread" do
    setup %{author: author, root: root, reader: reader} do
      reply =
        status_fixture(%{
          account_id: reader.id,
          text: "an answer",
          in_reply_to_id: root.id,
          in_reply_to_account_id: author.id
        })

      deeper =
        status_fixture(%{
          account_id: author.id,
          text: "a follow-up",
          in_reply_to_id: reply.id,
          in_reply_to_account_id: reader.id
        })

      %{reply: reply, deeper: deeper}
    end

    test "shows what came before and what came after", %{
      conn: conn,
      reply: reply,
      reader: reader
    } do
      html = conn |> get(at(reply, reader)) |> html_response(200)

      assert html =~ "the first post"
      assert html =~ "an answer"
      assert html =~ "a follow-up"
    end

    test "marks which post the page is about", %{conn: conn, reply: reply, reader: reader} do
      html = conn |> get(at(reply, reader)) |> html_response(200)

      assert html =~ "aria-current=\"true\""
    end

    test "keeps a private reply away from a stranger", %{
      conn: conn,
      author: author,
      root: root
    } do
      # A thread is exactly where a private reply sits next to public ones.
      status_fixture(%{
        account_id: author.id,
        text: "a quiet answer",
        visibility: :private,
        in_reply_to_id: root.id,
        in_reply_to_account_id: author.id
      })

      html = conn |> get(at(root, author)) |> html_response(200)

      refute html =~ "a quiet answer"
    end
  end

  describe "moving between posts" do
    test "each post can be focused, so a keyboard can walk the thread", %{
      conn: conn,
      root: root,
      author: author
    } do
      html = conn |> get(at(root, author)) |> html_response(200)

      assert html =~ ~s(tabindex="-1")
      assert html =~ ~s(data-post)
    end

    test "each post carries the link the open shortcut follows", %{
      conn: conn,
      root: root,
      author: author
    } do
      # The shortcuts page lists a key for this, and a listed key that does
      # nothing is worse than no page at all.
      html = conn |> get(at(root, author)) |> html_response(200)

      assert html =~ "data-post-link"
      assert html =~ at(root, author)
    end
  end

  describe "fetching the rest of a thread" do
    setup do
      remote = remote_account_fixture(%{username: "carol", domain: "remote.example"})

      theirs =
        status_fixture(%{
          account_id: remote.id,
          text: "a post from far away",
          local: false,
          uri: "https://remote.example/statuses/1"
        })

      %{remote: remote, theirs: theirs}
    end

    test "asks the other server for what it does not hold", %{
      signed_in: conn,
      remote: remote,
      theirs: theirs
    } do
      # A reply that lives on a server nobody here follows is a reply this one
      # has never been sent. Asking for it is the only way to show it.
      me = self()

      {:ok, live, _html} = live(conn, "/@carol@remote.example/#{theirs.id}")

      send(
        live.pid,
        {:test_fetcher,
         fn uri ->
           send(me, {:asked, uri})

           {:ok,
            status_fixture(%{
              account_id: remote.id,
              text: "an answer from far away",
              local: false,
              uri: "https://remote.example/statuses/2",
              in_reply_to_id: theirs.id,
              in_reply_to_account_id: remote.id
            })}
         end}
      )

      html = live |> element("button[phx-click='fetch_replies']") |> render_click()

      assert_received {:asked, "https://remote.example/statuses/1"}
      assert html =~ "an answer from far away"
    end

    test "says so when the other server cannot be reached", %{signed_in: conn, theirs: theirs} do
      {:ok, live, _html} = live(conn, "/@carol@remote.example/#{theirs.id}")

      send(live.pid, {:test_fetcher, fn _uri -> {:error, :unreachable} end})

      html = live |> element("button[phx-click='fetch_replies']") |> render_click()

      assert html =~ "could not be reached"
    end

    test "is not offered to somebody who is not signed in", %{conn: conn, theirs: theirs} do
      # Fetching makes this server talk to another one, which is not something
      # a passer-by gets to make it do.
      html = conn |> get("/@carol@remote.example/#{theirs.id}") |> html_response(200)

      refute html =~ "fetch_replies"
    end

    test "is not offered for a post this server owns", %{
      signed_in: conn,
      root: root,
      author: author
    } do
      html = conn |> get(at(root, author)) |> html_response(200)

      refute html =~ "fetch_replies"
    end
  end

  describe "acting on a post from its own page" do
    test "favouriting works here too", %{signed_in: conn, root: root, author: author} do
      {:ok, live, _html} = live(conn, at(root, author))

      live
      |> element("button[phx-click=favourite][phx-value-id='#{root.id}']")
      |> render_click()

      assert Repo.get_by(Favourite, status_id: root.id)
    end

    test "replying opens the box with the thread's people in it", %{
      signed_in: conn,
      root: root,
      author: author
    } do
      {:ok, live, _html} = live(conn, at(root, author))

      live |> element("button[phx-click=reply][phx-value-id='#{root.id}']") |> render_click()

      assert live |> element("#compose-text") |> render() =~ "@bob"
    end

    test "a passer-by gets no compose box", %{conn: conn, root: root, author: author} do
      html = conn |> get(at(root, author)) |> html_response(200)

      refute html =~ "compose-form"
    end

    test "a blocked reader is not shown the post", %{
      signed_in: conn,
      author: author,
      root: root,
      reader: reader
    } do
      {:ok, _} = Relationships.block(author, reader)

      assert_error_sent 404, fn -> get(conn, at(root, author)) end
    end
  end

  describe "translating" do
    setup do
      on_exit(fn -> Application.delete_env(:abuuba, :translation_provider) end)

      :ok
    end

    test "the button is not offered where the server cannot translate", %{signed_in: conn} do
      # A button that answers "not enabled" is worse than no button.
      author = account_fixture()
      status = status_fixture(%{account_id: author.id, text: "hallo", language: "de"})

      {:ok, _live, html} = live(conn, ~p"/@#{author.username}/#{status.id}")

      refute html =~ ~s(phx-click="translate")
    end

    test "and replaces the post once it is pressed", %{signed_in: conn} do
      author = account_fixture()
      status = status_fixture(%{account_id: author.id, text: "hallo", language: "de"})

      Application.put_env(:abuuba, :translation_provider, Fake)

      Fake.set(fn texts, _source, target, _opts ->
        {:ok, Enum.map(texts, &("[#{target}] " <> &1))}
      end)

      Translation.expire_all()

      {:ok, live, _html} = live(conn, ~p"/@#{author.username}/#{status.id}")

      html = live |> element(~s(button[phx-click="translate"])) |> render_click()

      assert html =~ "[en]"
      assert html =~ "Translated by Fake"
    end
  end
end
