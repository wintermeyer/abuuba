defmodule AbuubaWeb.HomeLiveTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Relationships
  alias Abuuba.Statuses

  setup %{conn: conn} do
    account = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    author = account_fixture(%{username: "bob", display_name: "Bob"})
    {:ok, _} = Relationships.follow(account, author)

    %{conn: log_in(conn, user), account: account, author: author}
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  describe "first paint" do
    test "is rendered by the server, before any socket connects", %{conn: conn, author: author} do
      # The point of the architecture: a reader sees the timeline without
      # waiting for JavaScript to fetch it.
      status_fixture(%{account_id: author.id, text: "hello from bob"})

      html = conn |> get(~p"/home") |> html_response(200)

      assert html =~ "hello from bob"
      assert html =~ "Bob"
    end

    test "says something useful when there is nothing yet", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/home")

      assert html =~ "Follow some people"
    end

    test "carries posts from the people somebody follows", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "theirs"})
      status_fixture(%{account_id: account_fixture().id, text: "a stranger"})

      {:ok, _live, html} = live(conn, ~p"/home")

      assert html =~ "theirs"
      refute html =~ "a stranger"
    end
  end

  describe "a content warning" do
    test "folds the post rather than removing it", %{conn: conn, author: author} do
      # A reader has to be able to tell there is something there and decide for
      # themselves.
      status_fixture(%{
        account_id: author.id,
        text: "the spoiler itself",
        spoiler_text: "spoilers ahead"
      })

      {:ok, _live, html} = live(conn, ~p"/home")

      assert html =~ "spoilers ahead"
      assert html =~ "<details"
      assert html =~ "the spoiler itself"
    end
  end

  describe "arriving posts" do
    test "go straight in when the reader is at the top", %{conn: conn, author: author} do
      {:ok, live, _html} = live(conn, ~p"/home")

      status_fixture(%{account_id: author.id, text: "just now"})

      assert render(live) =~ "just now"
    end

    test "wait when the reader has scrolled away", %{conn: conn, author: author} do
      # A post arriving while somebody is reading pushes what they were reading
      # down the screen, every few seconds on a busy timeline.
      {:ok, live, _html} = live(conn, ~p"/home")

      render_hook(live, "at_top", %{"value" => false})

      status_fixture(%{account_id: author.id, text: "later"})

      html = render(live)
      assert html =~ "1 new post"
      refute html =~ "later"

      assert live |> element("button", "1 new post") |> render_click() =~ "later"
    end

    test "somebody's own post never waits", %{conn: conn, account: account} do
      # A timeline that does not show you what you just said reads as though
      # the post failed.
      {:ok, live, _html} = live(conn, ~p"/home")

      render_hook(live, "at_top", %{"value" => false})

      status_fixture(%{account_id: account.id, text: "mine"})

      assert render(live) =~ "mine"
    end

    test "but not from somebody the reader muted", %{conn: conn, account: account, author: author} do
      # A mute deliberately leaves the follow in place -- that is what it is
      # for -- so a muted author still reaches this timeline over the socket.
      # The reloaded timeline hides them, so the words appear while somebody
      # watches and are gone the moment they refresh.
      {:ok, _} = Relationships.mute(account, author, %{})

      {:ok, live, _html} = live(conn, ~p"/home")

      status_fixture(%{account_id: author.id, text: "muted words"})

      refute render(live) =~ "muted words"
    end

    test "and not a boost of somebody they muted", %{
      conn: conn,
      account: account,
      author: author
    } do
      stranger = account_fixture(%{username: "carol"})
      original = status_fixture(%{account_id: stranger.id, text: "repeated words"})
      {:ok, _} = Relationships.mute(account, stranger, %{})

      {:ok, live, _html} = live(conn, ~p"/home")

      {:ok, _boost} = Statuses.boost(author, original)

      refute render(live) =~ "repeated words"
    end

    test "while an ordinary post still arrives", %{conn: conn, account: account, author: author} do
      # The control. Hiding everything would satisfy both tests above.
      {:ok, _} = Relationships.mute(account, account_fixture(), %{})

      {:ok, live, _html} = live(conn, ~p"/home")

      status_fixture(%{account_id: author.id, text: "ordinary words"})

      assert render(live) =~ "ordinary words"
    end

    test "a deleted post leaves the timeline", %{conn: conn, author: author} do
      status = status_fixture(%{account_id: author.id, text: "temporary"})

      {:ok, live, html} = live(conn, ~p"/home")
      assert html =~ "temporary"

      {:ok, _} = Statuses.delete_status(status)

      refute render(live) =~ "temporary"
    end
  end

  # The compose box has pressed buttons of its own, so a check on the whole
  # page would pass whatever the post's row says.
  defp row(live, status) do
    live |> element("#statuses-#{status.id}") |> render()
  end

  describe "the filters somebody set" do
    setup %{account: account} do
      {:ok, warn} =
        Abuuba.Filters.create(account, %{
          title: "No spoilers",
          context: ["home"],
          filter_action: "warn",
          keywords_attributes: [%{keyword: "ending", whole_word: true}]
        })

      %{filter: warn}
    end

    test "fold a matching post away, naming the rule", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "the ending was good"})

      {:ok, _live, html} = live(conn, ~p"/home")

      assert html =~ "No spoilers"
      assert html =~ "Show anyway"
    end

    test "leave everything else alone", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "nothing in particular"})

      {:ok, _live, html} = live(conn, ~p"/home")

      # The positive control: a timeline that folded everything would pass
      # every assertion above.
      assert html =~ "nothing in particular"
      refute html =~ "No spoilers"
    end

    test "keep the words readable once the fold is opened", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "the ending was good"})

      {:ok, _live, html} = live(conn, ~p"/home")

      # Folded rather than withheld: `warn` means the reader decides, so the
      # post has to be in the page for them to open. Inside a `details`, and
      # inside the one naming the rule rather than beside it.
      assert html =~ "the ending was good"
      assert html =~ "<details"
      assert [_fold] = Regex.scan(~r/data-post="/, html)
    end

    test "remove a post the rule said to hide", %{conn: conn, account: account, author: author} do
      {:ok, _hide} =
        Abuuba.Filters.create(account, %{
          title: "Never again",
          context: ["home"],
          filter_action: "hide",
          keywords_attributes: [%{keyword: "elections", whole_word: true}]
        })

      status_fixture(%{account_id: author.id, text: "about the elections"})
      status_fixture(%{account_id: author.id, text: "about the weather"})

      {:ok, _live, html} = live(conn, ~p"/home")

      refute html =~ "about the elections"
      # And the rule's own name stays off the page: "hide" means the reader
      # asked not to be told there was something to see.
      refute html =~ "Never again"

      assert html =~ "about the weather"
    end

    test "apply to a post that arrives while somebody is watching", %{
      conn: conn,
      author: author
    } do
      {:ok, live, _html} = live(conn, ~p"/home")

      status_fixture(%{account_id: author.id, text: "the ending was good"})

      # A post arriving live went through a render that named no context, so
      # the same post was filtered on reload and not while somebody watched.
      assert render(live) =~ "No spoilers"
    end

    test "apply to a post whose poll the reader just voted in", %{
      conn: conn,
      account: account,
      author: author
    } do
      status = status_fixture(%{account_id: author.id, text: "the ending was good"})

      {:ok, poll} =
        Statuses.create_poll(status, %{
          options: ["yes", "no"],
          tallies: [0, 0],
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      {:ok, live, _html} = live(conn, ~p"/home")

      render_click(live, "vote", %{"poll" => to_string(poll.id), "choices" => ["0"]})

      assert account
      assert render(live) =~ "No spoilers"
    end

    test "do not apply where the rule does not", %{conn: conn, account: account, author: author} do
      {:ok, _elsewhere} =
        Abuuba.Filters.create(account, %{
          title: "Only on profiles",
          context: ["account"],
          filter_action: "warn",
          keywords_attributes: [%{keyword: "weather", whole_word: true}]
        })

      status_fixture(%{account_id: author.id, text: "about the weather"})
      status_fixture(%{account_id: author.id, text: "the ending was good"})

      {:ok, _live, html} = live(conn, ~p"/home")

      # A filter set for one place must not quietly apply everywhere. The
      # home-context rule from the setup is the positive control: without it
      # this passes against a page that folds nothing at all.
      refute html =~ "Only on profiles"
      assert html =~ "No spoilers"
    end

    test "drop a hidden arrival rather than counting it as waiting", %{
      conn: conn,
      account: account,
      author: author
    } do
      {:ok, _hide} =
        Abuuba.Filters.create(account, %{
          title: "Never again",
          context: ["home"],
          filter_action: "hide",
          keywords_attributes: [%{keyword: "elections", whole_word: true}]
        })

      {:ok, live, _html} = live(conn, ~p"/home")
      render_hook(live, "at_top", %{"value" => false})

      status_fixture(%{account_id: author.id, text: "about the elections"})

      html = render(live)

      # "1 new post" about something somebody said they never wanted to hear
      # of is the existence of it, told.
      refute html =~ "new post"
      refute html =~ "about the elections"
    end

    test "still counts and shows an arrival nothing matched", %{conn: conn, author: author} do
      {:ok, live, _html} = live(conn, ~p"/home")
      render_hook(live, "at_top", %{"value" => false})

      status_fixture(%{account_id: author.id, text: "about the weather"})

      # The positive control for the two refusals above.
      assert render(live) =~ "1 new post"
      assert live |> element("button", "1 new post") |> render_click() =~ "about the weather"
    end

    test "fold a waiting arrival when it is shown", %{conn: conn, author: author} do
      {:ok, live, _html} = live(conn, ~p"/home")
      render_hook(live, "at_top", %{"value" => false})

      status_fixture(%{account_id: author.id, text: "the ending was good"})

      html = live |> element("button", "1 new post") |> render_click()

      # The waiting list used to be rendered again on the way out, which
      # skipped the filtering the arrival had already been through.
      assert html =~ "No spoilers"
    end

    test "drop a hidden post arriving while the reader is at the top", %{
      conn: conn,
      account: account,
      author: author
    } do
      {:ok, _hide} =
        Abuuba.Filters.create(account, %{
          title: "Never again",
          context: ["home"],
          filter_action: "hide",
          keywords_attributes: [%{keyword: "elections", whole_word: true}]
        })

      {:ok, live, _html} = live(conn, ~p"/home")

      status_fixture(%{account_id: author.id, text: "about the elections"})

      # `filter_action` is a string column, and this compared it against an
      # atom, so every hidden post arrived in full while somebody watched.
      refute render(live) =~ "about the elections"
    end
  end

  describe "a post's words" do
    test "renders the links the text asked for, as links", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "about #elixir"})

      {:ok, _live, html} = live(conn, ~p"/home")

      assert html =~ ~s(class="hashtag")
      refute html =~ "&lt;a href"
    end

    test "shows a paragraph as a paragraph rather than as its markup", %{
      conn: conn,
      author: author
    } do
      status_fixture(%{account_id: author.id, text: "first\n\nsecond"})

      {:ok, _live, html} = live(conn, ~p"/home")

      refute html =~ "&lt;p&gt;"
    end
  end

  describe "acting on a post" do
    setup %{author: author} do
      %{status: status_fixture(%{account_id: author.id, text: "act on me"})}
    end

    test "favouriting and taking it back", %{conn: conn, status: status, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live
      |> element("button[phx-click=favourite][phx-value-id='#{status.id}']")
      |> render_click()

      assert row(live, status) =~ ~s(aria-pressed="true")
      assert Statuses.get_status(status.id, account)

      live
      |> element("button[phx-click=favourite][phx-value-id='#{status.id}']")
      |> render_click()

      refute row(live, status) =~ ~s(aria-pressed="true")
    end

    test "boosting", %{conn: conn, status: status} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-click=boost][phx-value-id='#{status.id}']") |> render_click()

      assert row(live, status) =~ ~s(aria-pressed="true")
    end

    test "bookmarking", %{conn: conn, status: status, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-click=bookmark][phx-value-id='#{status.id}']") |> render_click()

      assert length(Statuses.bookmarks(account)) == 1
    end

    test "the row is redrawn from the database, not from what the click assumed",
         %{conn: conn, status: status, account: account} do
      # A refusal then corrects the display instead of being hidden by it.
      {:ok, live, _html} = live(conn, ~p"/home")

      {:ok, _} = Statuses.favourite(account, status)

      live
      |> element("button[phx-click=favourite][phx-value-id='#{status.id}']")
      |> render_click()

      # The click asked to toggle and the server had already recorded one, so
      # what comes back is the unfavourited state rather than a double count.
      refute row(live, status) =~ ~s(aria-pressed="true")
    end
  end

  describe "voting" do
    test "records a vote and redraws the result", %{conn: conn, author: author} do
      status = status_fixture(%{account_id: author.id, text: "pick one"})
      {:ok, poll} = Statuses.create_poll(status, %{options: ["yes", "no"]})

      {:ok, live, html} = live(conn, ~p"/home")
      assert html =~ "Vote"

      html = live |> form("form[phx-submit=vote]", %{"choices" => ["0"]}) |> render_submit()

      assert html =~ "100%"
      assert Statuses.own_votes(poll, socket_account(live)) == [0]
    end

    test "shows the result rather than the choices once somebody has voted", %{
      conn: conn,
      author: author,
      account: account
    } do
      # Showing the tally before a vote would change the vote, which is the one
      # thing a poll must not do.
      status = status_fixture(%{account_id: author.id})
      {:ok, poll} = Statuses.create_poll(status, %{options: ["yes", "no"]})
      {:ok, _} = Statuses.vote(poll, account, [1])

      {:ok, _live, html} = live(conn, ~p"/home")

      refute html =~ "phx-submit=\"vote\""
      assert html =~ "100%"
    end
  end

  describe "paging" do
    test "loads older posts on demand", %{conn: conn, author: author} do
      for i <- 1..25, do: status_fixture(%{account_id: author.id, text: "post #{i}"})

      {:ok, live, html} = live(conn, ~p"/home")

      # The first page is the newest twenty, so posts 1 to 5 are not in it.
      refute html =~ "post 5"

      assert render_hook(live, "load_older", %{}) =~ "post 5"
    end

    test "says when there is no more", %{conn: conn, author: author} do
      status_fixture(%{account_id: author.id, text: "only one"})

      {:ok, _live, html} = live(conn, ~p"/home")

      assert html =~ "reached the end"
    end
  end

  describe "the read marker" do
    test "remembers where somebody was", %{conn: conn, author: author, account: account} do
      status = status_fixture(%{account_id: author.id})

      {:ok, live, _html} = live(conn, ~p"/home")

      render_hook(live, "mark_read", %{"id" => to_string(status.id)})

      assert %{"home" => marker} = Abuuba.Timelines.markers(account, ["home"])
      assert marker.last_read_id == status.id
    end
  end

  defp socket_account(live) do
    :sys.get_state(live.pid).socket.assigns.account
  end
end
