defmodule AbuubaWeb.AccountDeletionTest do
  use AbuubaWeb.ConnCase, async: false
  use Oban.Testing, repo: Abuuba.Repo

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.Deletion
  alias Abuuba.Accounts.User
  alias Abuuba.Filters
  alias Abuuba.Moderation.PurgeWorker
  alias Abuuba.OAuth
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Statuses

  @password "a passphrase nobody guesses"

  setup %{conn: conn} do
    account = account_fixture(%{username: "alice"})

    user =
      %{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()}
      |> user_fixture()
      |> User.password_changeset(%{password: @password})
      |> Repo.update!()

    %{conn: log_in(conn, user), account: account, user: user}
  end

  describe "closing an account" do
    test "needs the right password", %{user: user, account: account} do
      assert {:error, :invalid_password} = Deletion.delete_own_account(user, "not it")

      assert is_nil(Repo.reload!(account).suspended_at)
      assert %User{} = Repo.reload(user)
    end

    test "hides it and takes the sign-in away at once", %{user: user} do
      {:ok, closed} = Deletion.delete_own_account(user, @password)

      assert closed.suspended_at
      assert closed.purge_after
      # Nobody can sign in to an account that is being deleted, including in
      # the window before the rows go.
      assert is_nil(Repo.reload(user))
    end

    test "revokes every app straight away", %{user: user} do
      {:ok, application, _secret} =
        OAuth.create_application(%{name: "app", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

      {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

      # A positive control: without it a refused request proves nothing.
      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> raw)
             |> get(~p"/api/v1/accounts/verify_credentials")
             |> json_response(200)

      {:ok, _closed} = Deletion.delete_own_account(user, @password)

      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> raw)
             |> get(~p"/api/v1/accounts/verify_credentials")
             |> json_response(422)
    end

    test "queues a Delete the peers can actually be sent", %{user: user, account: account} do
      remote =
        account_fixture(%{
          username: "far",
          domain: "remote.example",
          inbox_url: "https://remote.example/inbox"
        })

      Relationships.follow(remote, account)
      {:ok, _keypair} = Accounts.create_keypair(account)

      {:ok, _closed} = Deletion.delete_own_account(user, @password)

      assert Enum.any?(Repo.all(Oban.Job), fn job ->
               job.worker == "Abuuba.Federation.DeliveryWorker" and
                 get_in(job.args, ["activity", "type"]) == "Delete"
             end)

      # The signing key has to outlive the delivery. Deleting the account row
      # in the same breath as queueing the job leaves the worker with no key,
      # and it drops the delivery rather than sending it — so no peer is ever
      # told that the account is gone.
      assert Accounts.active_keypair(Repo.reload!(account))
    end

    test "really deletes everything once the purge runs", %{user: user, account: account} do
      other = account_fixture(%{username: "bob"})
      Relationships.follow(account, other)
      Relationships.follow(other, account)
      Relationships.block(account, account_fixture())
      Relationships.mute(account, account_fixture())
      status = status_fixture(%{account_id: account.id, text: "a thing I said"})
      Statuses.bookmark(account, status_fixture(%{account_id: other.id}))

      {:ok, _filter} =
        Filters.create(account, %{
          title: "No spoilers",
          context: ["home"],
          filter_action: "warn",
          keywords_attributes: [%{keyword: "ending", whole_word: true}]
        })

      {:ok, closed} = Deletion.delete_own_account(user, @password)

      # Its window brought forward, which is the only thing the passage of
      # time would have changed.
      closed
      |> Ecto.Changeset.change(purge_after: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

      assert :ok = perform_job(PurgeWorker, %{})

      # Every one of these hangs off the account row by a foreign key, and none
      # of them goes until that row does.
      assert is_nil(Repo.reload(account))
      assert is_nil(Repo.get(Abuuba.Statuses.Status, status.id))
      assert Relationships.following(other, %{limit: 10}) == []
      assert Filters.all(account.id) == []
    end

    test "leaves the counters of everybody else right", %{user: user, account: account} do
      other = account_fixture(%{username: "bob"})
      Relationships.follow(other, account)
      Relationships.follow(account, other)

      # A positive control: without it this test passes just as happily on
      # counters that were never bumped in the first place.
      before = Abuuba.Stats.account_stats(other)
      assert before.following_count == 1
      assert before.followers_count == 1

      {:ok, closed} = Deletion.delete_own_account(user, @password)

      closed
      |> Ecto.Changeset.change(purge_after: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

      :ok = perform_job(PurgeWorker, %{})

      # The counters unwind in the same breath as the rows they count. Doing it
      # earlier would leave everybody who knew the leaver short by one forever,
      # with nothing left to recount from.
      counts = Abuuba.Stats.account_stats(other)
      assert counts.following_count == 0
      assert counts.followers_count == 0
    end

    test "refuses to close a remote account or a closed one", %{user: user} do
      remote = account_fixture(%{username: "far", domain: "remote.example"})

      assert_raise FunctionClauseError, fn -> Deletion.close(remote) end
      {:ok, _closed} = Deletion.delete_own_account(user, @password)
      assert {:error, :not_found} = Deletion.delete_own_account(user, @password)
    end
  end

  describe "the username afterwards" do
    setup %{user: user} do
      {:ok, _closed} = Deletion.delete_own_account(user, @password)

      :ok
    end

    test "is held even after the row is gone" do
      assert Deletion.username_taken?("alice")
      # Case does not get somebody around it.
      assert Deletion.username_taken?("ALICE")
      refute Deletion.username_taken?("bob")
    end

    test "survives the purge that deletes the account", %{account: account} do
      account
      |> Repo.reload!()
      |> Ecto.Changeset.change(purge_after: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

      :ok = perform_job(PurgeWorker, %{})

      assert is_nil(Repo.reload(account))
      assert Deletion.username_taken?("alice")
    end

    test "cannot be registered again" do
      assert {:error, changeset} =
               Auth.register(%{
                 "username" => "alice",
                 "email" => "someone-else@example.com",
                 "password" => "a completely different passphrase",
                 "agreement" => "true",
                 "invite_reason" => "I would like to join this server"
               })

      assert %{username: [_ | _]} = errors_on(changeset)
    end

    test "still lets a different name through" do
      assert {:ok, _user} =
               Auth.register(%{
                 "username" => "carol",
                 "email" => "carol@example.com",
                 "password" => "a completely different passphrase",
                 "agreement" => "true",
                 "invite_reason" => "I would like to join this server"
               })
    end
  end

  describe "the settings page" do
    test "offers the form", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/export")

      assert html =~ "Close this account"
      assert html =~ "delete-account-form"
    end

    test "closes the account when the password is right", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/export")

      live |> form("#delete-account-form", %{"password" => @password}) |> render_submit()

      assert Repo.reload!(account).suspended_at
    end

    test "says so when it is not", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/export")

      html =
        live |> form("#delete-account-form", %{"password" => "not it"}) |> render_submit()

      assert html =~ "not your password"
      assert is_nil(Repo.reload!(account).suspended_at)
    end
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
