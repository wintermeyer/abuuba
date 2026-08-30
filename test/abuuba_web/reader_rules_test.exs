defmodule AbuubaWeb.ReaderRulesTest do
  @moduledoc """
  Blocks and mutes, on every page that shows a stranger's posts.

  `Abuuba.Timelines.public/2` and `Abuuba.Timelines.tag/3` apply them through
  `Abuuba.Statuses.excluding_hidden/2`, and that is what the API answers with.
  The browser's own explore and hashtag pages did not go through either: they
  asked `Statuses.public_timeline/1` and `Statuses.tag_timeline/2` directly,
  neither of which is told who is reading. So a person somebody had blocked
  was hidden from their home timeline and their search results, and sat on
  explore and on every hashtag page -- the two screens a reader lands on most
  after their own timeline.

  Written per surface rather than per rule, because the bug is not that a rule
  was wrong. It is that two surfaces never asked.
  """
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Relationships

  @tag_name "readerrules"

  setup %{conn: conn} do
    reader = account_fixture(%{username: "reader"})

    user =
      user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

    stranger = account_fixture(%{username: "stranger", display_name: "A Stranger"})

    status =
      status_fixture(%{
        account_id: stranger.id,
        text: "loud opinion about ##{@tag_name}",
        visibility: :public
      })

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))

    %{conn: conn, reader: reader, stranger: stranger, status: status}
  end

  defp surfaces, do: [{"explore", "/explore"}, {"the hashtag page", "/tags/#{@tag_name}"}]

  describe "before anybody is blocked or muted" do
    test "every surface shows the post", %{conn: conn} do
      # The control. Every assertion below is that something is absent, which a
      # page showing nothing at all would satisfy just as well.
      for {name, path} <- surfaces() do
        {:ok, _live, html} = live(conn, path)

        assert html =~ "loud opinion", "#{name} showed nothing to begin with"
      end
    end
  end

  describe "somebody the reader blocked" do
    setup %{reader: reader, stranger: stranger} do
      {:ok, _} = Relationships.block(reader, stranger)
      :ok
    end

    test "is off every surface", %{conn: conn} do
      for {name, path} <- surfaces() do
        {:ok, _live, html} = live(conn, path)

        refute html =~ "loud opinion", "#{name} showed a blocked account's post"
      end
    end
  end

  describe "somebody the reader muted" do
    setup %{reader: reader, stranger: stranger} do
      {:ok, _} = Relationships.mute(reader, stranger)
      :ok
    end

    test "is off every surface", %{conn: conn} do
      for {name, path} <- surfaces() do
        {:ok, _live, html} = live(conn, path)

        refute html =~ "loud opinion", "#{name} showed a muted account's post"
      end
    end
  end

  describe "somebody who blocked the reader" do
    setup %{reader: reader, stranger: stranger} do
      {:ok, _} = Relationships.block(stranger, reader)
      :ok
    end

    test "is off every surface too", %{conn: conn} do
      # The half a reader cannot fix themselves, and the one that matters to
      # the person who pressed the button.
      for {name, path} <- surfaces() do
        {:ok, _live, html} = live(conn, path)

        refute html =~ "loud opinion", "#{name} showed a post to somebody blocked by its author"
      end
    end
  end

  describe "a stranger reading the same pages" do
    test "still sees it, blocks being nobody else's business", %{conn: conn} do
      stranger_conn = Phoenix.ConnTest.build_conn()

      for {name, path} <- surfaces() do
        {:ok, _live, html} = live(stranger_conn, path)

        assert html =~ "loud opinion", "#{name} hid a public post from somebody signed out"
      end

      assert conn
    end
  end
end
