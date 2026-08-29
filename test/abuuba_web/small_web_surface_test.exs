defmodule AbuubaWeb.SmallWebSurfaceTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Mail.Unsubscribe
  alias Abuuba.OAuth
  alias Abuuba.Repo
  alias Abuuba.Settings

  setup do
    account = account_fixture(%{username: "alice", display_name: "Alice"})

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    on_exit(fn -> Settings.put("custom_css", "") end)

    %{account: account, user: user}
  end

  describe "GET /manifest" do
    test "describes the server as it is named now", %{conn: conn} do
      Settings.put("site_title", "Gardening Club")

      body = conn |> get(~p"/manifest") |> json_response(200)

      # Built from the settings rather than written out, so a server that
      # renames itself does not leave the old name on everybody's home screen.
      assert body["name"] == "Gardening Club"
      assert body["start_url"] == "/"
      assert body["display"] == "standalone"
    end

    test "says where a share from the operating system lands", %{conn: conn} do
      body = conn |> get(~p"/manifest") |> json_response(200)

      # Without it, "share to" offers this server and then opens the front
      # page, which reads as the share having been lost.
      assert body["share_target"]["action"] == "/share"
    end

    test "is also at the address some browsers look for", %{conn: conn} do
      assert conn |> get(~p"/manifest.json") |> json_response(200)
    end

    test "points at an icon that brings its own background", %{conn: conn} do
      body = conn |> get(~p"/manifest") |> json_response(200)

      # An installed app is drawn on whatever wallpaper the reader chose, so
      # the home-screen icon is the square one rather than the transparent
      # mark that sits beside the wordmark in the sidebar.
      assert [%{"src" => "/images/icon.svg"}] = body["icons"]
    end
  end

  describe "the icons a browser looks for" do
    # Declaring an icon in the layout does nothing if the file is not in
    # `static_paths`: the markup is right, the tab is empty, and nothing
    # anywhere says so. That omission is what this is here to catch.
    for path <-
          ~w(/favicon.ico /apple-touch-icon.png /images/logo.svg /images/icon.svg) do
      test "serves #{path}", %{conn: conn} do
        conn = get(conn, unquote(path))

        assert conn.status == 200
        assert conn.resp_body != ""
      end
    end

    test "no longer ships the Phoenix bird", %{conn: conn} do
      # The generator's logo shipped as the sidebar mark and as the home-screen
      # icon until somebody noticed it in a screenshot. #FD4F00 is its orange,
      # and finding it again means a generator has been re-run over the top.
      for path <- ~w(/images/logo.svg /images/icon.svg) do
        refute get(conn, path).resp_body =~ "FD4F00"
      end
    end
  end

  describe "GET /custom.css" do
    test "serves the admin's stylesheet as CSS", %{conn: conn} do
      Settings.put("custom_css", ".post { color: rebeccapurple }")

      conn = get(conn, ~p"/custom.css")

      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "text/css"
      assert response(conn, 200) =~ "rebeccapurple"
    end

    test "is empty rather than missing when nothing is set", %{conn: conn} do
      # A missing stylesheet is a 404 in every browser console on the server.
      assert conn |> get(~p"/custom.css") |> response(200) == ""
    end

    test "is linked from every page", %{conn: conn} do
      assert conn |> get(~p"/about") |> html_response(200) =~ "/custom.css"
    end
  end

  describe "the userinfo endpoint" do
    setup %{user: user} do
      {:ok, application, _secret} =
        OAuth.create_application(%{name: "sso", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

      {:ok, _token, raw} = OAuth.issue_token(application, user, ["read"])

      %{token: raw}
    end

    test "says who the bearer is", %{conn: conn, account: account, token: token} do
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get(~p"/oauth/userinfo")
        |> json_response(200)

      # The id and not the name: a name can be changed and a subject
      # identifier may not, or every system trusting this one would follow the
      # rename to whoever holds the name next.
      assert body["sub"] == to_string(account.id)
      assert body["preferred_username"] == "alice"
      assert body["name"] == "Alice"
    end

    test "answers a POST the same way", %{conn: conn, token: token} do
      assert conn
             |> put_req_header("authorization", "Bearer " <> token)
             |> post(~p"/oauth/userinfo")
             |> json_response(200)
    end

    test "refuses without a token", %{conn: conn} do
      assert conn |> get(~p"/oauth/userinfo") |> json_response(401)
    end

    test "is advertised where a single-sign-on client looks", %{conn: conn} do
      assert conn |> get(~p"/.well-known/openid-configuration") |> json_response(200)
    end
  end

  describe "unsubscribing" do
    test "a token this server did not sign is not a token" do
      assert :error = Unsubscribe.verify("nonsense")
      assert :error = Unsubscribe.verify(nil)
    end

    test "shows a page rather than acting on the click", %{conn: conn, user: user} do
      token = Unsubscribe.token(user, "notifications")

      body = conn |> get(~p"/unsubscribe/#{token}") |> html_response(200)

      assert body =~ "Stop these emails"
      # Mail clients fetch every link in a message before anybody reads it.
      assert Unsubscribe.wants?(Repo.reload!(user), "notifications")
    end

    test "acts when the button is pressed", %{conn: conn, user: user} do
      token = Unsubscribe.token(user, "notifications")

      conn |> post(~p"/unsubscribe/#{token}") |> redirected_to()

      reloaded = Repo.reload!(user)
      refute Unsubscribe.wants?(reloaded, "notifications")
      # And only that kind.
      assert Unsubscribe.wants?(reloaded, "digest")
    end

    test "turning everything off turns everything off", %{conn: conn, user: user} do
      conn |> post(~p"/unsubscribe/#{Unsubscribe.token(user, "all")}") |> redirected_to()

      reloaded = Repo.reload!(user)
      refute Unsubscribe.wants?(reloaded, "notifications")
      refute Unsubscribe.wants?(reloaded, "digest")
    end

    test "says nothing useful about a link that is not one", %{conn: conn} do
      assert conn |> get(~p"/unsubscribe/nonsense") |> redirected_to() == "/"
    end

    test "never expires", %{user: user} do
      # Somebody finding a year-old message and wanting the mail to stop is
      # exactly the person this exists for. The alternative is that they mark
      # it as spam, which costs the whole server's reputation.
      token = Unsubscribe.token(user, "notifications")

      assert {:ok, _id, "notifications"} = Unsubscribe.verify(token)
    end
  end
end
