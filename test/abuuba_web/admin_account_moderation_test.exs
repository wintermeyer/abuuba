defmodule AbuubaWeb.AdminAccountModerationTest do
  use AbuubaWeb.ConnCase, async: false
  use Oban.Testing, repo: Abuuba.Repo

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.User
  alias Abuuba.Admin
  alias Abuuba.Moderation.Actions
  alias Abuuba.OAuth
  alias Abuuba.Repo
  alias Abuuba.Roles

  @password "a passphrase nobody guesses"

  setup %{conn: conn} do
    subject = account_fixture(%{username: "trouble"})

    subject_user =
      %{account_id: subject.id, approved: true, confirmed_at: DateTime.utc_now()}
      |> user_fixture()
      |> User.password_changeset(%{password: @password})
      |> Repo.update!()

    %{
      conn: log_in(conn, staff(["manage_users", "manage_user_access", "delete_user_data"])),
      subject: subject,
      subject_user: subject_user
    }
  end

  defp staff(permissions) do
    {:ok, role} =
      Roles.create(%{
        name: "Role #{System.unique_integer([:positive])}",
        position: 900,
        permissions: Roles.mask(permissions)
      })

    user =
      user_fixture(%{
        account_id: account_fixture().id,
        approved: true,
        confirmed_at: DateTime.utc_now()
      })

    {:ok, user} = Roles.assign(user, role)

    user
  end

  describe "the moderator's note" do
    test "is kept, and the account is never told", %{conn: conn, subject: subject} do
      {:ok, live, _html} = live(conn, ~p"/admin/accounts/#{subject.id}")

      live
      |> form("#moderation-note-form", %{"note" => "Third report about the same joke"})
      |> render_submit()

      assert Repo.reload!(subject).moderation_note == "Third report about the same joke"

      # A note is not a strike: nothing is applied and nobody is told.
      assert Actions.strikes(subject) == []
    end

    test "is cleared by saving an empty one", %{conn: conn, subject: subject} do
      {:ok, _saved} = Admin.put_moderation_note(account_fixture(), subject, "Something")

      {:ok, live, _html} = live(conn, ~p"/admin/accounts/#{subject.id}")
      live |> form("#moderation-note-form", %{"note" => "   "}) |> render_submit()

      assert is_nil(Repo.reload!(subject).moderation_note)
    end

    test "is written to the audit log", %{subject: subject} do
      {:ok, _saved} = Admin.put_moderation_note(account_fixture(%{username: "mod"}), subject, "x")

      assert Enum.any?(Admin.audit_log(%{}), &(&1.action == "account.note"))
    end
  end

  describe "forcing a password reset" do
    test "ends every session and app, and mails a link", %{
      conn: conn,
      subject: subject,
      subject_user: subject_user
    } do
      session = Auth.create_session_token(subject_user)

      {:ok, application, _secret} =
        OAuth.create_application(%{name: "app", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

      {:ok, _token, raw} = OAuth.issue_token(application, subject_user, ["read"])

      # A positive control, so the refutations below mean something.
      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> raw)
             |> get(~p"/api/v1/accounts/verify_credentials")
             |> json_response(200)

      {:ok, live, _html} = live(conn, ~p"/admin/accounts/#{subject.id}")
      live |> element("button[phx-click='force_password_reset']") |> render_click()

      assert is_nil(Auth.get_user_by_session_token(session))

      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> raw)
             |> get(~p"/api/v1/accounts/verify_credentials")
             |> json_response(422)

      assert Enum.any?(Repo.all(Oban.Job), &(&1.worker == "Abuuba.Accounts.PasswordResetWorker"))
    end

    test "does not choose the new password", %{subject: subject, subject_user: subject_user} do
      :ok = Admin.force_password_reset(account_fixture(), subject)

      # A password a moderator picked is a password a moderator knows. The old
      # one still works until its owner uses the link.
      assert %User{} = Auth.get_user_by_email_and_password(subject_user.email, @password)
    end

    test "says so for an account with nobody to sign in as" do
      remote = account_fixture(%{domain: "remote.example"})

      assert {:error, :no_user} = Admin.force_password_reset(account_fixture(), remote)
    end
  end

  describe "fetching a remote profile again" do
    test "is offered only for a remote account", %{conn: conn, subject: subject} do
      {:ok, _live, html} = live(conn, ~p"/admin/accounts/#{subject.id}")

      refute html =~ "refetch_account"
    end

    test "is refused for a local one", %{subject: subject} do
      assert {:error, :local} = Admin.refetch(account_fixture(), subject)
    end
  end

  describe "the account's posts" do
    test "are listed on the screen", %{conn: conn, subject: subject} do
      status_fixture(%{account_id: subject.id, text: "<p>something they said</p>"})

      {:ok, _live, html} = live(conn, ~p"/admin/accounts/#{subject.id}")

      assert html =~ "something they said"
    end

    test "can be deleted from it", %{conn: conn, subject: subject} do
      status = status_fixture(%{account_id: subject.id, text: "<p>something they said</p>"})

      {:ok, live, _html} = live(conn, ~p"/admin/accounts/#{subject.id}")
      live |> element("button[phx-value-status='#{status.id}']") |> render_click()

      assert Repo.reload!(status).deleted_at
    end

    test "deleting one is written to the audit log", %{conn: conn, subject: subject} do
      status = status_fixture(%{account_id: subject.id, text: "<p>gone</p>"})

      {:ok, live, _html} = live(conn, ~p"/admin/accounts/#{subject.id}")
      live |> element("button[phx-value-status='#{status.id}']") |> render_click()

      entry = Admin.audit_log(%{}) |> Enum.find(&(&1.action == "status.delete"))

      assert entry
      assert entry.details["status_id"] == to_string(status.id)
    end

    test "an id from another account is refused", %{conn: conn, subject: subject} do
      other = status_fixture(%{account_id: account_fixture().id, text: "<p>not theirs</p>"})

      {:ok, live, _html} = live(conn, ~p"/admin/accounts/#{subject.id}")
      render_click(live, "delete_status", %{"status" => to_string(other.id)})

      # Scoped to the posts on the screen, so a typed id is only ever one of
      # those.
      assert is_nil(Repo.reload!(other).deleted_at)
    end
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end
end
