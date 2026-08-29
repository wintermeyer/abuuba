defmodule AbuubaWeb.PublicPagesTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Admin
  alias Abuuba.Federation.URIs
  alias Abuuba.Instance
  alias Abuuba.Moderation.Signup
  alias Abuuba.Settings

  setup %{conn: conn} do
    author = account_fixture(%{username: "bob", display_name: "Bob"})
    status = status_fixture(%{account_id: author.id, text: "something worth quoting"})

    reader = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

    %{conn: conn, signed_in: log_in(conn, user), author: author, status: status}
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  describe "the about page" do
    test "says what this server is and who runs it", %{conn: conn} do
      # Written the way the admin screen writes it rather than by putting the
      # key this page happens to read: the two had drifted apart, and a test
      # that sets the key under test can never notice.
      :ok =
        Admin.put_settings(account_fixture(), %{
          "site_contact_email" => "admin@example.test",
          # The long description had no field on the admin screen at all, so
          # this page's own subject was unreachable: only a test could set it.
          "extended_description" => "A server for gardeners."
        })

      html = conn |> get(~p"/about") |> html_response(200)

      assert html =~ "A server for gardeners."
      assert html =~ "admin@example.test"
    end

    test "lists the rules people agreed to", %{conn: conn} do
      {:ok, _} = Settings.create_rule(%{text: "Be kind", position: 1})

      html = conn |> get(~p"/about") |> html_response(200)

      assert html =~ "Be kind"
    end

    test "shows the numbers", %{conn: conn} do
      html = conn |> get(~p"/about") |> html_response(200)

      assert html =~ "people"
      assert html =~ "posts"
    end

    test "says whether anybody can join", %{conn: conn} do
      html = conn |> get(~p"/about") |> html_response(200)

      assert html =~ "Registration"
    end

    test "links the terms and the privacy policy", %{conn: conn} do
      html = conn |> get(~p"/about") |> html_response(200)

      assert html =~ ~s(href="/terms")
      assert html =~ ~s(href="/privacy")
    end
  end

  describe "terms and privacy" do
    test "shows what an admin wrote, with when it took effect", %{conn: conn} do
      # Published the way the admin screen publishes it -- a row per version --
      # rather than by writing a settings key nothing else sets. The page had a
      # second source of truth beside the rows that no screen could fill.
      {:ok, _} =
        Instance.publish_terms(account_fixture(), %{
          text: "Do not be a nuisance.",
          effective_date: ~D[2026-01-01]
        })

      html = conn |> get(~p"/terms") |> html_response(200)

      assert html =~ "Do not be a nuisance."
      # The reader's date, not the stored one. The path still carries ISO.
      assert html =~ "Jan 1, 2026"
    end

    test "and the privacy policy an admin wrote", %{conn: conn} do
      # There was no way to write one at all: the page and
      # `/api/v1/instance/privacy_policy` both read keys that no screen sets,
      # so every server running this answered an empty policy however much its
      # operator wanted to publish one.
      :ok =
        Admin.put_settings(account_fixture(), %{
          "privacy_text" => "We keep what you write and nothing else.",
          "privacy_effective_on" => "2026-02-01"
        })

      html = conn |> get(~p"/privacy") |> html_response(200)

      assert html =~ "We keep what you write and nothing else."
      assert html =~ "Feb 1, 2026"

      body =
        conn |> get(~p"/api/v1/instance/privacy_policy") |> json_response(200)

      assert body["content"] =~ "nothing else"
      assert body["updated_at"] == "2026-02-01"
    end

    test "says so plainly when an admin has written nothing", %{conn: conn} do
      # A blank page reads as broken. Saying there is nothing yet is honest and
      # tells an admin what to do.
      html = conn |> get(~p"/privacy") |> html_response(200)

      assert html =~ "has not been written"
    end
  end

  describe "the embed" do
    test "renders the post on its own, with no navigation around it", %{
      conn: conn,
      status: status
    } do
      html = conn |> get(~p"/embed/#{status.id}") |> html_response(200)

      assert html =~ "something worth quoting"
      refute html =~ ~s(aria-label="Main")
    end

    test "can be framed, which is the whole point of it", %{conn: conn, status: status} do
      conn = get(conn, ~p"/embed/#{status.id}")

      assert get_resp_header(conn, "x-frame-options") == []
      assert get_resp_header(conn, "content-security-policy") == ["frame-ancestors *"]
    end

    test "every other page refuses to be framed", %{conn: conn} do
      # Otherwise this server's pages can be wrapped in somebody else's chrome
      # and a click aimed at their page lands on ours.
      conn = get(conn, ~p"/about")

      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert hd(get_resp_header(conn, "content-security-policy")) =~ "frame-ancestors 'none'"
    end

    test "shows nothing private", %{conn: conn, author: author} do
      quiet =
        status_fixture(%{account_id: author.id, text: "for followers", visibility: :private})

      assert_error_sent 404, fn -> get(conn, ~p"/embed/#{quiet.id}") end
    end

    test "a post nobody has is a plain miss", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/embed/999999999999") end
    end

    test "links back to the post it is showing", %{conn: conn, status: status} do
      html = conn |> get(~p"/embed/#{status.id}") |> html_response(200)

      assert html =~ "/@bob/#{status.id}"
    end
  end

  describe "oEmbed" do
    test "describes a post as an embeddable thing", %{conn: conn, status: status} do
      url = "#{URIs.base_url()}/@bob/#{status.id}"

      body = conn |> get(~p"/api/oembed?#{[url: url]}") |> json_response(200)

      assert body["type"] == "rich"
      assert body["provider_name"] == Abuuba.Instance.software_name()
      assert body["author_name"] == "Bob"
      assert body["html"] =~ "<iframe"
      assert body["html"] =~ "/embed/#{status.id}"
    end

    test "honours the width somebody asked for", %{conn: conn, status: status} do
      url = "#{URIs.base_url()}/@bob/#{status.id}"

      body = conn |> get(~p"/api/oembed?#{[url: url, maxwidth: 320]}") |> json_response(200)

      assert body["width"] == 320
      assert body["html"] =~ ~s(width="320")
    end

    test "refuses a width nobody could mean", %{conn: conn, status: status} do
      url = "#{URIs.base_url()}/@bob/#{status.id}"

      body =
        conn |> get("/api/oembed?url=#{URI.encode(url)}&maxwidth=99999999") |> json_response(200)

      assert body["width"] <= 1000
    end

    test "refuses an address on another server", %{conn: conn} do
      # A stranger's URL turned into an embed of ours would let this server be
      # used to frame anything anybody names.
      conn = get(conn, ~p"/api/oembed?#{[url: "https://elsewhere.example/@bob/1"]}")

      assert conn.status == 404
    end

    test "refuses an address that is not a post", %{conn: conn} do
      conn = get(conn, ~p"/api/oembed?#{[url: "#{URIs.base_url()}/about"]}")

      assert conn.status == 404
    end

    test "a post's page says where its oEmbed lives", %{conn: conn, status: status} do
      # Without the link tag, nothing discovers the endpoint.
      html = conn |> get(~p"/@bob/#{status.id}") |> html_response(200)

      assert html =~ ~s(application/json+oembed)
    end
  end

  describe "sharing" do
    test "puts what was handed over into the box", %{signed_in: conn} do
      {:ok, _live, html} = live(conn, ~p"/share?#{[text: "look at this"]}")

      assert html =~ "look at this"
    end

    test "carries a title and a link together", %{signed_in: conn} do
      {:ok, _live, html} =
        live(conn, ~p"/share?#{[title: "A page", url: "https://a.test/page"]}")

      assert html =~ "A page"
      assert html =~ "https://a.test/page"
    end

    test "asks somebody who is not signed in to sign in first", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/share?#{[text: "hello"]}")

      assert to =~ "/login"
    end
  end

  describe "handing an interaction back to somebody's own server" do
    test "offers to take a visitor home", %{conn: conn, status: status} do
      # Somebody reading this from another server cannot follow or reply here:
      # their account lives elsewhere, and this is the page that says so.
      uri = "#{URIs.base_url()}/@bob/#{status.id}"

      html = conn |> get(~p"/authorize_interaction?#{[uri: uri]}") |> html_response(200)

      assert html =~ "your own server"
      assert html =~ ~s(name="handle")
    end

    test "sends them to their own server's search", %{conn: conn, status: status} do
      uri = "#{URIs.base_url()}/@bob/#{status.id}"

      {:ok, live, _html} = live(conn, ~p"/authorize_interaction?#{[uri: uri]}")

      assert {:error, {:redirect, %{to: url}}} =
               live
               |> form("#handoff-form", %{"handle" => "carol@remote.example"})
               |> render_submit()

      assert url =~ "remote.example"
      assert url =~ URI.encode_www_form(uri)
    end

    test "refuses a handle that is not one", %{conn: conn, status: status} do
      uri = "#{URIs.base_url()}/@bob/#{status.id}"

      {:ok, live, _html} = live(conn, ~p"/authorize_interaction?#{[uri: uri]}")

      html = live |> form("#handoff-form", %{"handle" => "not a handle"}) |> render_submit()

      assert html =~ "name@server"
    end

    test "takes somebody who is already signed in straight to the post", %{
      signed_in: conn,
      status: status
    } do
      uri = "#{URIs.base_url()}/@bob/#{status.id}"

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/authorize_interaction?#{[uri: uri]}")

      assert to == "/@bob/#{status.id}"
    end

    test "refuses to send somebody to an address on this server as if it were theirs", %{
      conn: conn,
      status: status
    } do
      uri = "#{URIs.base_url()}/@bob/#{status.id}"

      {:ok, live, _html} = live(conn, ~p"/authorize_interaction?#{[uri: uri]}")

      html =
        live
        |> form("#handoff-form", %{"handle" => "bob@#{URIs.local_host()}"})
        |> render_submit()

      assert html =~ "this server"
    end
  end

  describe "an address shut out entirely" do
    test "cannot read a page", %{conn: conn} do
      # The plug reads the socket address, which is 127.0.0.1 in a test.
      {:ok, _} =
        Signup.block_ip(account_fixture(), %{
          "cidr" => "127.0.0.1/32",
          "severity" => "no_access"
        })

      conn = get(conn, ~p"/about")

      assert conn.status == 403
      assert conn.resp_body =~ "does not accept requests"
    end

    test "and a sign-up block does not do that", %{conn: conn} do
      # A sign-up block is about registering and says nothing about reading.
      {:ok, _} =
        Signup.block_ip(account_fixture(), %{
          "cidr" => "127.0.0.1/32",
          "severity" => "sign_up_block"
        })

      assert html_response(get(conn, ~p"/about"), 200)
    end
  end
end
