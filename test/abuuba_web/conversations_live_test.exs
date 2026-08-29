defmodule AbuubaWeb.ConversationsLiveTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Conversations
  alias Abuuba.Statuses

  setup %{conn: conn} do
    reader = account_fixture(%{username: "alice"})
    sender = account_fixture(%{username: "bob", display_name: "Bob"})

    user =
      user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

    %{conn: log_in(conn, user), reader: reader, sender: sender}
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  # A direct message from `sender` to `reader`, delivered the way a real one is
  # so the inbox row is written by the code that writes it in production.
  defp message(sender, reader, text) do
    {:ok, status} =
      Statuses.create_status(%{
        account_id: sender.id,
        text: text,
        visibility: :direct
      })

    {:ok, _} = Statuses.mention(status, reader)
    :ok = Conversations.deliver(Abuuba.Repo.reload!(status))

    status
  end

  describe "the inbox" do
    test "says so when there is nothing in it", %{conn: conn} do
      html = conn |> get(~p"/conversations") |> html_response(200)

      assert html =~ "Nothing here yet"
    end

    test "lists a conversation by who is in it, with the last message", %{
      conn: conn,
      reader: reader,
      sender: sender
    } do
      message(sender, reader, "are you coming on Thursday")

      html = conn |> get(~p"/conversations") |> html_response(200)

      assert html =~ "@bob"
      assert html =~ "are you coming on Thursday"
      # The reader is not listed as somebody they are talking to.
      refute html =~ "@alice,"
    end

    test "opening one marks it read and goes to the thread", %{
      conn: conn,
      reader: reader,
      sender: sender
    } do
      status = message(sender, reader, "a question")
      [row] = Conversations.list(reader)
      assert row.unread

      {:ok, live, _html} = live(conn, ~p"/conversations")

      assert {:error, {:live_redirect, %{to: to}}} =
               live |> element("button[phx-click='open']") |> render_click()

      assert to == "/@bob/#{status.id}"
      refute Conversations.get(reader, row.id).unread
    end

    test "marking it unread again puts it back", %{
      conn: conn,
      reader: reader,
      sender: sender
    } do
      message(sender, reader, "a question")
      [row] = Conversations.list(reader)
      {:ok, _} = Conversations.mark_read(reader, row.id)

      {:ok, live, _html} = live(conn, ~p"/conversations")

      live |> element("button[phx-click='unread']") |> render_click()

      assert Conversations.get(reader, row.id).unread
    end

    test "removing one takes it out of the inbox", %{
      conn: conn,
      reader: reader,
      sender: sender
    } do
      message(sender, reader, "a question")
      assert [_row] = Conversations.list(reader)

      {:ok, live, _html} = live(conn, ~p"/conversations")

      live |> element("button[phx-click='remove']") |> render_click()

      assert Conversations.list(reader) == []
      assert render(live) =~ "Nothing here yet"
    end

    test "and somebody else's inbox is not reachable by guessing an id", %{
      conn: conn,
      reader: reader,
      sender: sender
    } do
      # A conversation belonging to a third party, whose row id the reader
      # sends by hand.
      stranger = account_fixture()
      other = account_fixture()
      status = message(other, stranger, "not for you")
      [theirs] = Conversations.list(stranger)

      {:ok, live, _html} = live(conn, ~p"/conversations")

      render_click(live, "remove", %{"id" => to_string(theirs.id)})
      render_click(live, "unread", %{"id" => to_string(theirs.id)})

      assert [kept] = Conversations.list(stranger)
      assert kept.id == theirs.id
      assert kept.last_status_id == status.id

      # The positive control: the same events do work on the reader's own row.
      message(sender, reader, "for you")
      [mine] = Conversations.list(reader)
      render_click(live, "remove", %{"id" => to_string(mine.id)})
      assert Conversations.list(reader) == []
    end
  end

  describe "an edit that names somebody new" do
    test "puts the message in their inbox too", %{reader: reader, sender: sender} do
      other = account_fixture(%{username: "carol"})

      {:ok, status} =
        Statuses.create_status(%{
          account_id: sender.id,
          text: "only for @alice",
          visibility: :direct
        })

      :ok = Conversations.deliver(Abuuba.Repo.reload!(status))

      assert [_row] = Conversations.list(reader)
      assert Conversations.list(other) == []

      {:ok, _} = Statuses.edit_status(status, %{"text" => "for @alice and @carol"})

      # The mention and the notification were already written by the edit; the
      # inbox row was the piece nobody repeated.
      assert [row] = Conversations.list(other)
      assert row.last_status_id == status.id
    end
  end

  describe "a message arriving while somebody is looking" do
    test "puts it in the inbox without a reload", %{
      conn: conn,
      reader: reader,
      sender: sender
    } do
      {:ok, live, html} = live(conn, ~p"/conversations")
      assert html =~ "Nothing here yet"

      message(sender, reader, "just now")

      # The broadcast reaches the LiveView through the same topic a streaming
      # socket listens on, so this exercises the wiring rather than the render.
      assert wait_for(live, "just now")
      refute render(live) =~ "Nothing here yet"
    end

    defp wait_for(live, text, tries \\ 40) do
      cond do
        render(live) =~ text -> true
        tries == 0 -> flunk("#{text} never appeared in the inbox")
        true -> Process.sleep(25) && wait_for(live, text, tries - 1)
      end
    end
  end

  describe "the navigation" do
    test "counts what is waiting, and gives the count an id of its own", %{
      conn: conn,
      reader: reader,
      sender: sender
    } do
      html = conn |> get(~p"/home") |> html_response(200)
      assert html =~ "Messages"
      refute html =~ "badge--conversations"

      message(sender, reader, "a question")
      message(account_fixture(), reader, "another")

      html = conn |> get(~p"/home") |> html_response(200)

      assert html =~ "badge--conversations"
      assert Conversations.unread_count(reader) == 2

      # Two counted links on one page, and the badge id used to be a constant.
      # Two elements sharing an id is invalid HTML and is the key LiveView
      # patches the DOM by, so it is worth an assertion rather than an eye.
      assert length(String.split(html, "badge--")) - 1 ==
               length(Enum.uniq(Regex.scan(~r/id="badge--[a-z-]+"/, html)))
    end
  end
end
