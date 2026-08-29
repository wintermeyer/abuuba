defmodule AbuubaWeb.API.AccountEntityTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.User
  alias Abuuba.Admin
  alias Abuuba.OAuth
  alias Abuuba.Repo
  alias Abuuba.Roles

  setup %{conn: conn} do
    account = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> raw),
      anon: build_conn(),
      account: account,
      user: user
    }
  end

  defp shown(conn, account), do: json_response(get(conn, "/api/v1/accounts/#{account.id}"), 200)

  describe "state a client branches on" do
    test "an ordinary account carries none of the flags", %{anon: anon, account: account} do
      # Present only when they apply. A `false` reads as "we checked", and an
      # absent key reads the same with less to carry.
      body = shown(anon, account)

      refute Map.has_key?(body, "suspended")
      refute Map.has_key?(body, "limited")
      refute Map.has_key?(body, "memorial")
      refute Map.has_key?(body, "moved")
    end

    test "says when somebody is silenced", %{anon: anon} do
      target = account_fixture()
      {:ok, _} = Accounts.update_moderation(target, %{silenced_at: DateTime.utc_now()})

      assert shown(anon, target)["limited"] == true
    end

    test "says when an account is a memorial", %{anon: anon, account: account} do
      moderator = account_fixture()
      target = account_fixture()

      {:ok, _} = Admin.memorialize(moderator, target)

      assert shown(anon, target)["memorial"] == true
      refute Map.has_key?(shown(anon, account), "memorial")
    end

    test "memorialising stops the login without hiding anything", %{} do
      moderator = account_fixture()
      target = account_fixture()
      user = user_fixture(%{account_id: target.id, approved: true})

      {:ok, updated} = Admin.memorialize(moderator, target)

      assert updated.memorial
      assert User.disabled?(Repo.reload!(user))
      # Nothing hidden: this is not a moderation action.
      refute updated.suspended_at
      refute updated.silenced_at
    end

    test "says where somebody moved to", %{anon: anon} do
      moved_to = account_fixture(%{username: "newhome"})
      target = account_fixture()

      {:ok, _} =
        Accounts.update_account(target, %{
          moved_to_account_id: moved_to.id,
          moved_at: DateTime.utc_now()
        })

      body = shown(anon, target)

      assert body["moved"]["id"] == to_string(moved_to.id)
      assert body["moved"]["username"] == "newhome"
      # One hop. A chain of migrations is not somebody's whole history unrolled
      # into one document.
      refute Map.has_key?(body["moved"], "moved")
    end
  end

  describe "noindex" do
    test "is the reader-facing spelling of the indexable choice", %{anon: anon} do
      target = account_fixture()
      {:ok, _} = Accounts.update_profile(target, %{"indexable" => false})

      assert shown(anon, target)["noindex"] == true

      {:ok, _} = Accounts.update_profile(target, %{"indexable" => true})
      assert shown(anon, target)["noindex"] == false
    end

    test "is absent for an account on another server", %{anon: anon} do
      # Their answer is on their own profile, not ours.
      remote = remote_account_fixture()

      refute Map.has_key?(shown(anon, remote), "noindex")
    end
  end

  describe "roles" do
    test "shows a role somebody chose to highlight, and hides the rest", %{
      anon: anon,
      account: account,
      user: user
    } do
      assert shown(anon, account)["roles"] == []

      {:ok, quiet} =
        Roles.create(%{
          name: "Janitor",
          position: 5,
          permissions: Roles.mask(["manage_reports"])
        })

      {:ok, _} = Roles.assign(user, quiet)

      # Not highlighted: it exists to grant permissions, and publishing it
      # would tell every reader how this server's moderation is organised.
      assert shown(anon, account)["roles"] == []

      {:ok, loud} =
        Roles.create(%{
          name: "Moderator",
          position: 6,
          color: "#ff0000",
          highlighted: true,
          permissions: Roles.mask(["manage_reports"])
        })

      {:ok, _} = Roles.assign(user, loud)

      assert [role] = shown(anon, account)["roles"]
      assert role["name"] == "Moderator"
      assert role["color"] == "#ff0000"
      assert role["highlighted"] == true
      assert is_binary(role["permissions"])
    end

    test "is empty for an account on another server", %{anon: anon} do
      assert shown(anon, remote_account_fixture())["roles"] == []
    end
  end
end
