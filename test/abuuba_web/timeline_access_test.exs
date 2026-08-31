defmodule AbuubaWeb.TimelineAccessTest do
  @moduledoc """
  Who may read the public timelines, on every surface that shows them.

  The API has enforced `timeline_access` since it was written -- `disabled` is
  a 404, `authenticated` a 422 for a reader with no token -- and nothing could
  set it, because no screen writes that key. The pages of this server's own
  interface do not consult it at all: the landing page, explore and a hashtag
  page each ask `Statuses` for public posts directly.

  So the enforcement was half built and unreachable, which is the worst of the
  three states it could be in: the moment somebody wires up the control, the
  server claims a privacy property it does not have, and the person who set it
  has no way to tell.

  These tests are the second half. The API cases are here beside the page
  cases deliberately -- the point is that one question has one answer wherever
  it is asked.
  """
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Auth
  alias Abuuba.Settings
  alias Abuuba.Trends

  setup do
    {:ok, author} = Accounts.update_profile(account_fixture(), %{"discoverable" => true})
    status = status_fixture(%{account_id: author.id, text: "in the square #outdoors"})

    # Trending is the same posts reached by a different door, and it was the
    # one door that asked nothing: no setting, and no viewer either.
    :ok = Trends.approve(account_fixture(), "status", to_string(status.id))
    Trends.put_counts("status", to_string(status.id), Date.utc_today(), accounts: 40)
    :ok = Trends.rank()

    on_exit(fn -> Settings.put("timeline_access", "public") end)

    %{author: author, status: status}
  end

  # Approved as well as confirmed: `Auth.check_sign_in/1` refuses an account
  # still waiting for a moderator, so a fixture without it is not "somebody
  # signed in" -- it is somebody the sign-in would turn away.
  defp signed_in(conn) do
    account = account_fixture()

    user =
      user_fixture(%{
        account_id: account.id,
        confirmed_at: DateTime.utc_now(),
        approved: true
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  describe "when a server keeps its timelines to itself" do
    setup do
      :ok = Settings.put("timeline_access", "authenticated")
      :ok
    end

    test "a stranger is not shown them on the pages here", %{conn: conn} do
      for path <- [~p"/", ~p"/explore", ~p"/tags/outdoors"] do
        html = conn |> get(path) |> html_response(200)

        refute html =~ "in the square",
               "#{path} showed a public post to somebody with no account"
      end
    end

    test "and the API says so rather than answering", %{conn: conn} do
      assert conn |> get(~p"/api/v1/timelines/public") |> json_response(422)
    end

    test "and through what is trending in tags and links, which summarise it", %{conn: conn} do
      # A tag entity carries how many people used it on each of the last seven
      # days, counted from exactly the posts this server has just refused to
      # show. A front page advertising #outdoors beside a /tags/outdoors that
      # answers nothing is the setting saying one thing and the door another.
      assert conn |> get(~p"/api/v1/trends/tags") |> json_response(200) == []
      assert conn |> get(~p"/api/v1/trends/links") |> json_response(200) == []

      # The tags tab still lists the tags this server has, because a directory
      # of names is not a timeline: what the setting withholds is the trend,
      # which is the counting of the posts behind them.
      assert Trends.tags(nil) == []
    end

    test "and says which silence it is rather than blaming an empty server", %{conn: conn} do
      # "Nothing here yet" is a lie on a server that has posts and is
      # refusing them, and it sends somebody away instead of telling them an
      # account would work.
      html = conn |> get(~p"/explore") |> html_response(200)

      refute html =~ "Nothing here yet"
      assert html =~ "those with an account here"
    end

    test "including through what is trending, which is the same posts", %{conn: conn} do
      # The door nobody had gated. `/api/v1/trends/statuses` read a ranking
      # table and handed the rows straight over: no setting, and no viewer, so
      # `Trends.eligible?/1` at write time was the whole of the check.
      assert conn |> get(~p"/api/v1/trends/statuses") |> json_response(200) == []

      refute conn |> get(~p"/explore") |> html_response(200) =~ "in the square"
    end

    test "but somebody signed in reads them as before", %{conn: conn} do
      # The positive half. Every assertion above is that something is absent,
      # which a server showing nobody anything would satisfy just as well.
      html = conn |> signed_in() |> get(~p"/explore") |> html_response(200)

      assert html =~ "in the square"
    end
  end

  describe "when a server turns them off entirely" do
    setup do
      :ok = Settings.put("timeline_access", "disabled")
      :ok
    end

    test "nobody is shown them, signed in or not", %{conn: conn} do
      refute conn |> get(~p"/explore") |> html_response(200) =~ "in the square"

      refute conn |> signed_in() |> get(~p"/explore") |> html_response(200) =~ "in the square",
             "off means off, including for the people who live here"
    end

    test "and trending is off with them", %{conn: conn} do
      assert conn |> get(~p"/api/v1/trends/statuses") |> json_response(200) == []

      assert conn |> signed_in() |> get(~p"/api/v1/trends/statuses") |> json_response(200) == []
    end
  end

  describe "which servers this one blocks, the sibling setting" do
    # `show_domain_blocks` has the same three shapes and had no accessor at
    # all: its one caller matched the raw string, so the next one would have
    # matched it slightly differently. Here beside `timeline_access` for the
    # reason the moduledoc gives -- one question, one answer.
    setup do
      on_exit(fn -> Settings.put("show_domain_blocks", "disabled") end)
      :ok
    end

    test "nobody by default", %{conn: conn} do
      refute Settings.domain_blocks_visible?(nil)
      refute Settings.domain_blocks_visible?(account_fixture())

      assert conn |> get(~p"/api/v1/instance/domain_blocks") |> json_response(404)
    end

    test "people with an account here, when set to users", %{conn: conn} do
      :ok = Settings.put("show_domain_blocks", "users")

      refute Settings.domain_blocks_visible?(nil)
      assert Settings.domain_blocks_visible?(account_fixture())

      assert conn |> get(~p"/api/v1/instance/domain_blocks") |> json_response(404),
             "a stranger is told nothing rather than that something is withheld"
    end

    test "anybody, when set to all", %{conn: conn} do
      :ok = Settings.put("show_domain_blocks", "all")

      assert Settings.domain_blocks_visible?(nil)
      assert conn |> get(~p"/api/v1/instance/domain_blocks") |> json_response(200) == []
    end
  end

  describe "a server that leaves them open" do
    test "shows them to anybody, which is the default", %{conn: conn} do
      assert Settings.timeline_access() == :public

      assert conn |> get(~p"/explore") |> html_response(200) =~ "in the square"
      assert conn |> get(~p"/api/v1/timelines/public") |> json_response(200) != []

      # The positive control for the two cases above: trending answers when
      # the setting allows it, so an empty list there means the gate and not a
      # ranking that was never built.
      assert conn |> get(~p"/api/v1/trends/statuses") |> json_response(200) != []
    end
  end
end
