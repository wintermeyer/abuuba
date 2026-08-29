defmodule AbuubaWeb.FollowLimitTest do
  @moduledoc """
  The follow allowance is spent by the places a person presses a button.

  `Abuuba.ActionLimits` has had a `follows` family since it was written, the
  documentation says four hundred a day, and there is a test proving the
  counter counts. Nothing called it. Following everybody and unfollowing
  whoever does not follow back is exactly what the number was chosen to stop,
  and it cost nothing to do.

  The counting belongs to the doors a person comes through rather than to
  `Relationships.follow/3` itself, because that is also how an inbound Follow,
  a Move, an invite's autofollow and the CSV importer write the row. Counting
  those would refuse somebody importing their own follow list, which is the
  one moment they legitimately follow hundreds of accounts at once.
  """

  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.ActionLimits
  alias Abuuba.OAuth
  alias Abuuba.RateLimit
  alias Abuuba.Relationships

  setup do
    RateLimit.reset()

    viewer = account_fixture()

    user =
      user_fixture(%{account_id: viewer.id, approved: true, confirmed_at: DateTime.utc_now()})

    %{viewer: viewer, user: user, target: account_fixture()}
  end

  defp sign_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  defp bearer(conn, user) do
    {:ok, app, _secret} =
      OAuth.create_application(%{name: "t", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(app, user, ["read", "write"])

    put_req_header(conn, "authorization", "Bearer " <> raw)
  end

  # Spent directly rather than by following four hundred accounts: the budget
  # is what is under test, not the ability to make fixtures.
  defp exhaust(account) do
    {limit, _window} = ActionLimits.family(:follows)

    for _ <- 1..limit, do: ActionLimits.take(account, :follows)

    :ok
  end

  describe "over the API" do
    test "a follow is refused once the day's allowance is gone", %{
      conn: conn,
      viewer: viewer,
      user: user,
      target: target
    } do
      :ok = exhaust(viewer)

      conn = conn |> bearer(user) |> post(~p"/api/v1/accounts/#{target.id}/follow")

      assert json_response(conn, 429)
      refute Relationships.following?(viewer, target)
    end

    test "and goes through while there is allowance left", %{
      conn: conn,
      viewer: viewer,
      user: user,
      target: target
    } do
      # The control. Refusing every follow would satisfy the test above.
      conn = conn |> bearer(user) |> post(~p"/api/v1/accounts/#{target.id}/follow")

      assert json_response(conn, 200)
      assert Relationships.following?(viewer, target)
    end
  end

  describe "from the browser" do
    test "the follow button on a profile spends the same allowance", %{
      conn: conn,
      viewer: viewer,
      user: user,
      target: target
    } do
      :ok = exhaust(viewer)

      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{target.username}")

      html = live |> element("button[phx-click='follow']") |> render_click()

      refute Relationships.following?(viewer, target)
      assert html =~ "Too many"
    end

    test "and it works when the allowance is there", %{
      conn: conn,
      viewer: viewer,
      user: user,
      target: target
    } do
      {:ok, live, _html} = live(sign_in(conn, user), ~p"/@#{target.username}")

      live |> element("button[phx-click='follow']") |> render_click()

      assert Relationships.following?(viewer, target)
    end
  end

  describe "from the suggestions screen" do
    test "explore spends the same allowance", %{conn: conn, viewer: viewer, user: user} do
      # The screen that suggests people to follow is the easiest place to build
      # a list from, so it is the last place that should go uncounted.
      target = account_fixture(%{discoverable: true})
      :ok = exhaust(viewer)

      {:ok, live, _html} = live(sign_in(conn, user), ~p"/explore")

      render_click(live, "follow", %{"account" => to_string(target.id)})

      refute Relationships.following?(viewer, target)
    end

    test "and follows when there is allowance", %{conn: conn, viewer: viewer, user: user} do
      target = account_fixture(%{discoverable: true})

      {:ok, live, _html} = live(sign_in(conn, user), ~p"/explore")

      render_click(live, "follow", %{"account" => to_string(target.id)})

      assert Relationships.following?(viewer, target)
    end
  end

  describe "what does not spend it" do
    test "an inbound follow from a peer is not the peer's budget to spend", %{viewer: viewer} do
      # A remote account following somebody here writes a row through the same
      # function. Counting it would let a busy peer exhaust an allowance that
      # belongs to one of its own users, and there is nobody here to tell.
      stranger = account_fixture(%{domain: "peer.example"})
      :ok = exhaust(stranger)

      assert {:ok, _edge} = Relationships.follow(stranger, viewer)
    end
  end
end
