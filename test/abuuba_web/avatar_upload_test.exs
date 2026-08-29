defmodule AbuubaWeb.AvatarUploadTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Media.ProfileImages
  alias Abuuba.Repo

  setup %{conn: conn} do
    account = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    %{conn: log_in(conn, user), account: account}
  end

  # A one-pixel PNG, so the pipeline has a real picture to scale rather than
  # bytes that happen to be named `.png`.
  defp png do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
  end

  defp upload(live, kind, name, content) do
    entry =
      file_input(live, "#picture-form-#{kind}", kind, [
        %{name: name, content: content, type: "image/png"}
      ])

    render_upload(entry, name)

    entry
  end

  describe "the profile page" do
    test "offers an avatar and a header field", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/profile")

      assert html =~ "Avatar"
      assert html =~ "Header"
      assert html =~ "picture-form-avatar"
    end

    test "says the limits before anybody picks a file", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/profile")

      # A limit somebody learns about after a failed upload is a limit that
      # wasted their time and this server's bandwidth.
      assert html =~ "JPEG, PNG, GIF or WebP"
      assert html =~ "8 MB"
    end

    test "no longer says pictures cannot be set here", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/profile")

      refute html =~ "cannot be uploaded on this page"
    end

    test "says when there is no picture yet", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/profile")

      assert html =~ "None yet."
    end
  end

  describe "uploading" do
    test "stores an avatar through the same path the API uses", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/profile")

      upload(live, :avatar, "me.png", png())
      live |> element("#picture-form-avatar") |> render_submit(%{"kind" => "avatar"})

      reloaded = Repo.reload!(account)
      assert reloaded.avatar_file_name
      assert reloaded.avatar_content_type == "image/png"
      assert ProfileImages.url(reloaded, :avatar) != ""
    end

    test "shows the picture once it is there", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/profile")

      upload(live, :avatar, "me.png", png())
      live |> element("#picture-form-avatar") |> render_submit(%{"kind" => "avatar"})

      reloaded = Repo.reload!(account)

      {:ok, _live, html} = live(conn, ~p"/settings/profile")

      assert html =~ ProfileImages.url(reloaded, :avatar)
      assert html =~ "Take it off"
    end

    test "takes one back off", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/profile")
      upload(live, :avatar, "me.png", png())
      live |> element("#picture-form-avatar") |> render_submit(%{"kind" => "avatar"})

      assert Repo.reload!(account).avatar_file_name

      {:ok, live, _html} = live(conn, ~p"/settings/profile")
      live |> element("button[phx-value-kind='avatar']") |> render_click()

      assert is_nil(Repo.reload!(account).avatar_file_name)
    end

    test "leaves the other picture alone", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/profile")

      upload(live, :avatar, "me.png", png())
      live |> element("#picture-form-avatar") |> render_submit(%{"kind" => "avatar"})

      reloaded = Repo.reload!(account)
      assert reloaded.avatar_file_name
      assert is_nil(reloaded.header_file_name)
    end

    test "refuses something that is not a picture", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/profile")

      entry =
        file_input(live, "#picture-form-avatar", :avatar, [
          %{name: "notes.png", content: "this is not a picture", type: "image/png"}
        ])

      render_upload(entry, "notes.png")

      html =
        live |> element("#picture-form-avatar") |> render_submit(%{"kind" => "avatar"})

      # The name said PNG and the bytes did not. Nothing is written, and the
      # account keeps whatever it had.
      assert html =~ "could not be saved" or html =~ "not a picture this server can use"
      assert is_nil(Repo.reload!(account).avatar_file_name)
    end
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end
end
