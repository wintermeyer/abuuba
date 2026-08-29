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

  alias Abuuba.Accounts.Auth
  alias Abuuba.Settings

  setup do
    author = account_fixture()
    status_fixture(%{account_id: author.id, text: "in the square #outdoors"})

    on_exit(fn -> Settings.put("timeline_access", "public") end)

    %{author: author}
  end

  defp signed_in(conn) do
    account = account_fixture()
    user = user_fixture(%{account_id: account.id, confirmed_at: DateTime.utc_now()})

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
  end

  describe "a server that leaves them open" do
    test "shows them to anybody, which is the default", %{conn: conn} do
      assert Settings.timeline_access() == :public

      assert conn |> get(~p"/explore") |> html_response(200) =~ "in the square"
      assert conn |> get(~p"/api/v1/timelines/public") |> json_response(200) != []
    end
  end
end
