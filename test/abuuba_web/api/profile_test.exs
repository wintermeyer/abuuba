defmodule AbuubaWeb.API.ProfileTest do
  @moduledoc """
  `/api/v1/profile`: what somebody sees when they are editing themselves,
  rather than what everybody else reads about them.

  The two answer different questions, which is why Mastodon has both. This one
  carries the raw text of a note as well as the rendered version, and carries
  no counters at all: a page for changing your name has no business reporting
  how many followers the change will reach.
  """

  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Media.ProfileImages
  alias Abuuba.OAuth

  @fixture_dir Path.join(System.tmp_dir!(), "abuuba-profile-api-test")

  setup do
    File.mkdir_p!(@fixture_dir)
    on_exit(fn -> File.rm_rf(@fixture_dir) end)

    account = account_fixture(%{username: "alice", display_name: "Alice", note: "hello"})

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    %{account: account, token: raw}
  end

  defp signed_in(token) do
    put_req_header(build_conn(), "authorization", "Bearer " <> token)
  end

  defp picture(name) do
    path = Path.join(@fixture_dir, name)

    {_output, 0} =
      System.cmd("ffmpeg", [
        "-y",
        "-f",
        "lavfi",
        "-i",
        "color=c=red:s=600x600",
        "-frames:v",
        "1",
        path
      ])

    %Plug.Upload{path: path, filename: name, content_type: MIME.from_path(name)}
  end

  describe "reading it" do
    test "carries the note both raw and rendered", %{token: token} do
      body = signed_in(token) |> get(~p"/api/v1/profile") |> json_response(200)

      assert body["display_name"] == "Alice"
      assert body["note"] == "hello"
      # One goes in the edit box, the other is what the profile will look like.
      assert body["formatted_note"] =~ "hello"
    end

    test "says null rather than empty for a picture that is not there", %{token: token} do
      body = signed_in(token) |> get(~p"/api/v1/profile") |> json_response(200)

      assert body["avatar"] == nil
      assert body["header_static"] == nil
    end

    test "is nobody's without a token", %{conn: conn} do
      # 422 with this message rather than 401, which is what `require_user!`
      # answers in the reference implementation and so what clients expect.
      assert conn |> get(~p"/api/v1/profile") |> json_response(422)
    end
  end

  describe "writing it" do
    test "changes the name", %{token: token} do
      body =
        signed_in(token)
        |> put(~p"/api/v1/profile", %{"display_name" => "Alicia"})
        |> json_response(200)

      assert body["display_name"] == "Alicia"
    end

    test "and takes a picture", %{token: token} do
      # multipart, because that is how a client sends a file and because a
      # Plug.Upload inside JSON params arrives as an ordinary map.
      body =
        signed_in(token)
        |> put_req_header("content-type", "multipart/form-data")
        |> patch(~p"/api/v1/profile", %{"avatar" => picture("a.png")})
        |> json_response(200)

      assert body["avatar"] =~ "/accounts/avatars/"
    end
  end

  describe "removing a picture" do
    setup %{account: account} do
      {:ok, attrs} = ProfileImages.store(account, :avatar, picture("a.png"))
      {:ok, account} = Accounts.update_account(account, attrs)

      %{account: account}
    end

    test "clears it", %{token: token} do
      # The positive control first: it really was there.
      assert signed_in(token)
             |> get(~p"/api/v1/profile")
             |> json_response(200)
             |> Map.fetch!("avatar") != nil

      body = signed_in(token) |> delete(~p"/api/v1/profile/avatar") |> json_response(200)

      assert body["avatar"] == nil
    end

    test "and a header that was never there is not an error", %{token: token} do
      assert signed_in(token) |> delete(~p"/api/v1/profile/header") |> json_response(200)
    end

    test "but a kind this server does not have is a 404", %{token: token} do
      assert signed_in(token) |> delete(~p"/api/v1/profile/nonsense") |> json_response(404)
    end
  end

  describe "a moderator removing one" do
    setup %{account: account} do
      {:ok, attrs} = ProfileImages.store(account, :avatar, picture("a.png"))
      {:ok, _account} = Accounts.update_account(account, attrs)

      moderator = account_fixture(%{username: "mod"})

      user =
        user_fixture(%{
          account_id: moderator.id,
          approved: true,
          confirmed_at: DateTime.utc_now()
        })

      {:ok, role} =
        Abuuba.Roles.create(%{name: "Moderator", permissions: Abuuba.Roles.bit("manage_users")})

      {:ok, _user} = Abuuba.Roles.assign(user, role)

      {:ok, application, _secret} =
        OAuth.create_application(%{name: "mod app", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

      {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write", "admin:write"])

      %{mod_token: raw}
    end

    test "takes it off somebody else's profile", %{mod_token: token, account: account} do
      body =
        signed_in(token)
        |> post("/api/v1/admin/accounts/#{account.id}/remove_avatar")
        |> json_response(200)

      assert body["id"] == "#{account.id}"

      assert Abuuba.Accounts.get_account(account.id) |> ProfileImages.url(:avatar) == ""
    end
  end
end
