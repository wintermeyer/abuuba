defmodule AbuubaWeb.ShellTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.Preferences
  alias AbuubaWeb.Hotkeys

  describe "the shell" do
    test "offers a way past the navigation before anything else", %{conn: conn} do
      # A keyboard user should not have to tab through every navigation link on
      # every page to reach what they came for.
      html = conn |> get(~p"/shortcuts") |> html_response(200)

      assert html =~ ~s(href="#main")
      assert html =~ "Skip to content"
    end

    test "the main region can be focused, so navigation can land there", %{conn: conn} do
      html = conn |> get(~p"/shortcuts") |> html_response(200)

      assert html =~ ~s(id="main")
      assert html =~ ~s(tabindex="-1")
    end

    test "carries one live region for announcements", %{conn: conn} do
      # Without it a reader who cannot see the screen is told nothing when a
      # post is sent, and the interface simply looks broken to them.
      html = conn |> get(~p"/shortcuts") |> html_response(200)

      assert html =~ ~s(id="live-region")
      assert html =~ ~s(aria-live="polite")
    end

    test "names its navigation for a screen reader", %{conn: conn} do
      html = conn |> get(~p"/shortcuts") |> html_response(200)

      assert html =~ ~s(aria-label="Main")
    end

    test "has no theme control, because the theme follows the system", %{conn: conn} do
      html = conn |> get(~p"/shortcuts") |> html_response(200)

      refute html =~ "phx-theme"
      refute html =~ "phx:theme"
    end
  end

  describe "navigation" do
    test "signed out, it offers only what a stranger can use", %{conn: conn} do
      # A "Home" that answers 422 would be an interface arguing with itself.
      html = conn |> get(~p"/shortcuts") |> html_response(200)

      assert html =~ "Explore"
      assert html =~ "Log in"
      refute html =~ "Notifications"
    end

    test "signed in, it offers the personal pages", %{conn: conn} do
      conn = log_in(conn)

      html = conn |> get(~p"/shortcuts") |> html_response(200)

      assert html =~ "Notifications"
      refute html =~ "Log in"
    end

    test "every destination it names is a real page", %{conn: conn} do
      # Navigation that leads to a 404 is not navigation anybody can test.
      for path <- [~p"/", ~p"/explore", ~p"/shortcuts"] do
        assert conn |> get(path) |> html_response(200)
      end
    end

    test "the signed-in pages load", %{conn: conn} do
      conn = log_in(conn)

      assert {:ok, _live, html} = live(conn, ~p"/notifications")
      assert html =~ "Notifications"
    end
  end

  describe "keyboard shortcuts" do
    test "the page lists every binding", %{conn: conn} do
      html = conn |> get(~p"/shortcuts") |> html_response(200)

      for shortcut <- Hotkeys.all() do
        assert html =~ shortcut.description
      end
    end

    test "the bindings a browser gets match the page", %{conn: conn} do
      # A shortcuts page listing a key that does nothing is worse than no page.
      html = conn |> get(~p"/shortcuts") |> html_response(200)
      bindings = Hotkeys.bindings()

      assert map_size(bindings) == length(Hotkeys.all())
      assert html =~ "hotkeys"
    end

    test "says plainly that typing is not commanding", %{conn: conn} do
      html = conn |> get(~p"/shortcuts") |> html_response(200)

      assert html =~ "typing"
    end
  end

  describe "accessibility preferences" do
    test "default to letting the browser decide" do
      assert Preferences.for_user(nil) == %{
               "reduce_motion" => false,
               "high_contrast" => false,
               "system_font" => false,
               "disable_autoplay" => false,
               "warn_missing_alt" => false
             }
    end

    test "are read off somebody's stored settings" do
      user = %{settings: %{"accessibility" => %{"reduce_motion" => true}}}

      assert Preferences.for_user(user)["reduce_motion"]
      refute Preferences.for_user(user)["high_contrast"]
    end

    test "become classes on the document, where they can reach everything" do
      # A preference like reduced motion has to reach elements a component
      # renders without knowing about it.
      classes = Preferences.body_class(%{"reduce_motion" => true, "high_contrast" => true})

      assert classes =~ "prefers-reduce-motion"
      assert classes =~ "prefers-high-contrast"
      refute classes =~ "system-font"
    end

    test "merging keeps whatever else was in the settings map" do
      settings = %{"locale" => "de", "accessibility" => %{"high_contrast" => true}}

      merged = Preferences.merge(settings, %{"reduce_motion" => "true"})

      assert merged["locale"] == "de"
      assert merged["accessibility"]["high_contrast"]
      assert merged["accessibility"]["reduce_motion"]
    end

    test "merging ignores keys nobody defined" do
      merged = Preferences.merge(%{}, %{"reduce_motion" => true, "invented" => true})

      refute Map.has_key?(merged["accessibility"], "invented")
    end

    test "reach the document for a signed-in person", %{conn: conn} do
      user = user_fixture(%{approved: true, confirmed_at: DateTime.utc_now()})

      {:ok, updated} =
        Abuuba.Accounts.update_user_settings(
          user,
          Preferences.merge(user.settings, %{"reduce_motion" => true})
        )

      html = conn |> log_in(updated) |> get(~p"/shortcuts") |> html_response(200)

      assert html =~ "prefers-reduce-motion"
    end
  end

  # The session token straight into the session, because `log_in_user/2` also
  # redirects and a test that followed it would be testing the redirect.
  defp log_in(conn, user \\ nil) do
    user = user || user_fixture(%{approved: true, confirmed_at: DateTime.utc_now()})
    token = Auth.create_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
