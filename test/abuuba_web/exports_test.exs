defmodule AbuubaWeb.ExportsTest do
  use AbuubaWeb.ConnCase, async: false
  use Oban.Testing, repo: Abuuba.Repo

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.User
  alias Abuuba.Exports
  alias Abuuba.Exports.Export
  alias Abuuba.Filters
  alias Abuuba.Lists
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

  describe "the CSVs" do
    test "carry the follows somebody has", %{account: account} do
      other = account_fixture(%{username: "bob"})
      Relationships.follow(account, other)

      csv = Exports.csv(account, "follows")

      assert csv =~ "Account address"
      assert csv =~ "bob"
    end

    test "carry blocks, mutes and blocked servers", %{account: account} do
      Relationships.block(account, account_fixture(%{username: "blocked"}))
      Relationships.mute(account, account_fixture(%{username: "muted"}))
      Relationships.block_domain(account, "noisy.example")

      assert Exports.csv(account, "blocks") =~ "blocked"
      assert Exports.csv(account, "mutes") =~ "muted"
      assert Exports.csv(account, "domain_blocks") =~ "noisy.example"
    end

    test "carry lists with a row per member", %{account: account} do
      {:ok, list} = Lists.create(account, %{title: "Gardeners"})
      member = account_fixture(%{username: "gardener"})
      Relationships.follow(account, member)
      :ok = Lists.add(list, [member.id])

      csv = Exports.csv(account, "lists")

      assert csv =~ "Gardeners"
      assert csv =~ "gardener"
    end

    test "carry bookmarks and filters", %{account: account} do
      status = status_fixture(%{account_id: account_fixture().id, text: "something"})
      Statuses.bookmark(account, status)

      {:ok, _filter} =
        Filters.create(account, %{
          title: "No spoilers",
          context: ["home"],
          filter_action: "warn",
          keywords_attributes: [%{keyword: "ending", whole_word: true}]
        })

      assert Exports.csv(account, "bookmarks") =~ "http"
      assert Exports.csv(account, "filters") =~ "No spoilers"
      assert Exports.csv(account, "filters") =~ "ending"
    end

    test "quote every field, so a comma in a name is not a new column", %{account: account} do
      other = account_fixture(%{username: "bob"})
      Relationships.follow(account, other)

      # A display name with a comma is the ordinary case, not the exception,
      # and a reader that has to guess is a reader that gets it wrong.
      assert Exports.csv(account, "follows") =~ ~s("bob")
    end

    test "answer nil for a kind this server does not export", %{account: account} do
      assert is_nil(Exports.csv(account, "everything"))
    end
  end

  describe "the export page" do
    test "renders, with every list and the archive section", %{conn: conn} do
      # A component whose assigns nobody wired up raises on mount, and every
      # test that only calls the context is green while the page is a 500.
      {:ok, _live, html} = live(conn, ~p"/settings/export")

      assert html =~ "A copy of everything"

      for kind <- Exports.kinds() do
        assert html =~ "/settings/export/lists/#{kind}"
      end
    end

    test "offers the download once an archive is built", %{conn: conn, account: account} do
      {:ok, export} = Exports.request(account)
      Oban.drain_queue(queue: :ingress)

      {:ok, _live, html} = live(conn, ~p"/settings/export")

      assert html =~ "/settings/export/archives/#{export.id}/download"
    end
  end

  describe "GET /settings/export/lists/:kind" do
    test "sends a file the browser saves", %{conn: conn, account: account} do
      Relationships.follow(account, account_fixture(%{username: "bob"}))

      conn = get(conn, ~p"/settings/export/lists/follows")

      assert response(conn, 200) =~ "bob"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "follows.csv"
    end

    test "refuses a kind that is not one", %{conn: conn} do
      assert conn |> get(~p"/settings/export/lists/secrets") |> redirected_to() =~ "/settings"
    end

    test "refuses anonymously" do
      assert build_conn() |> get(~p"/settings/export/lists/follows") |> redirected_to()
    end
  end

  describe "the archive" do
    test "is built, and holds the account and its posts", %{account: account} do
      status_fixture(%{account_id: account.id, text: "a thing I said"})

      {:ok, export} = Exports.request(account)
      Oban.drain_queue(queue: :ingress)

      export = Repo.reload!(export)
      assert export.state == "done", "archive failed: #{export.error}"
      assert export.size > 0

      {:ok, files} = :zip.unzip(to_charlist(export.path), [:memory])
      names = Enum.map(files, fn {name, _body} -> to_string(name) end)

      assert "actor.json" in names
      assert "outbox.json" in names
      assert "follows.csv" in names

      {_name, outbox} = Enum.find(files, fn {name, _} -> to_string(name) == "outbox.json" end)
      assert outbox =~ "a thing I said"
      assert %{"orderedItems" => [_ | _]} = Jason.decode!(outbox)
    end

    test "writes a readable outbox for an account with no posts at all", %{account: account} do
      {:ok, export} = Exports.request(account)
      Oban.drain_queue(queue: :ingress)

      {:ok, files} = :zip.unzip(to_charlist(Repo.reload!(export).path), [:memory])
      {_name, outbox} = Enum.find(files, fn {name, _} -> to_string(name) == "outbox.json" end)

      # The comma-between-items writer is where an empty collection goes wrong.
      assert %{"orderedItems" => []} = Jason.decode!(outbox)
    end

    test "emails the person who asked", %{account: account} do
      {:ok, _export} = Exports.request(account)
      Oban.drain_queue(queue: :ingress)

      assert_email_sent(fn email ->
        assert email.text_body =~ "/settings/export/archives/"
      end)
    end

    test "refuses a second one while the first is being built", %{account: account} do
      {:ok, _export} = Exports.request(account)

      assert {:error, :in_progress} = Exports.request(account)
    end

    test "refuses another one within the week", %{account: account} do
      {:ok, _export} = Exports.request(account)
      Oban.drain_queue(queue: :ingress)

      assert {:error, {:too_soon, %DateTime{}}} = Exports.request(account)
    end

    test "allows one once the week has passed", %{account: account} do
      {:ok, export} = Exports.request(account)
      Oban.drain_queue(queue: :ingress)

      age(export, Exports.cooldown_days() + 1)

      assert {:ok, _fresh} = Exports.request(account)
    end
  end

  describe "GET /settings/export/archives/:id/download" do
    setup %{account: account} do
      {:ok, export} = Exports.request(account)
      Oban.drain_queue(queue: :ingress)

      %{export: Repo.reload!(export)}
    end

    test "sends the file to its owner", %{conn: conn, export: export} do
      conn = get(conn, ~p"/settings/export/archives/#{export.id}/download")

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ".zip"
    end

    test "refuses somebody else's", %{export: export} do
      stranger = account_fixture()

      other_user =
        %{account_id: stranger.id, approved: true, confirmed_at: DateTime.utc_now()}
        |> user_fixture()

      # An archive is a whole account in one file, so an id somebody can guess
      # must not be an id somebody can download.
      assert build_conn()
             |> log_in(other_user)
             |> get(~p"/settings/export/archives/#{export.id}/download")
             |> redirected_to() =~ "/settings"
    end

    test "refuses an id too large for the column", %{conn: conn} do
      assert conn
             |> get(~p"/settings/export/archives/99999999999999999999/download")
             |> redirected_to() =~ "/settings"
    end

    test "refuses one that has expired", %{conn: conn, export: export} do
      export |> Ecto.Changeset.change(expires_at: past()) |> Repo.update!()

      assert conn
             |> get(~p"/settings/export/archives/#{export.id}/download")
             |> redirected_to() =~ "/settings"
    end
  end

  describe "the CSV values" do
    test "carry what the follow actually says, not the defaults", %{account: account} do
      other = account_fixture(%{username: "bob"})
      Relationships.follow(account, other)

      Abuuba.Relationships.Follow
      |> Repo.get_by(account_id: account.id, target_account_id: other.id)
      |> Ecto.Changeset.change(show_reblogs: false, notify: true)
      |> Repo.update!()

      # Writing the defaults would make the round trip actively harmful:
      # importing this elsewhere would switch boosts back on for somebody who
      # had turned them off.
      assert Exports.csv(account, "follows") =~ ~s("bob","false","true")
    end

    test "carry what the mute actually says", %{account: account} do
      other = account_fixture(%{username: "quiet"})
      Relationships.mute(account, other, hide_notifications: false)

      assert Exports.csv(account, "mutes") =~ ~s("quiet","false")
    end
  end

  describe "an archive whose job never finished" do
    test "is written off, so the account is not locked out forever", %{account: account} do
      {:ok, export} = Exports.request(account)

      # A job killed rather than raised — a deploy, a restart, a timeout —
      # never marks its row, and a row stuck on `running` blocks every later
      # request with no expiry for the sweep to find.
      export
      |> Ecto.Changeset.change(
        state: "running",
        updated_at: DateTime.add(DateTime.utc_now(), -1, :day)
      )
      |> Repo.update!()

      assert {:error, :in_progress} = Exports.request(account)

      Exports.sweep()

      assert Repo.reload!(export).state == "failed"
      assert {:ok, _fresh} = Exports.request(account)
    end
  end

  describe "the archive file" do
    test "is not readable by anybody else on the machine", %{account: account} do
      {:ok, export} = Exports.request(account)
      Oban.drain_queue(queue: :ingress)

      %{mode: mode} = File.stat!(Repo.reload!(export).path)

      # Somebody's whole account at a path whose only secret would otherwise be
      # a sequential id.
      assert Bitwise.band(mode, 0o077) == 0
    end
  end

  describe "sweeping archives" do
    test "takes the file with the row", %{account: account} do
      {:ok, export} = Exports.request(account)
      Oban.drain_queue(queue: :ingress)

      export = Repo.reload!(export)
      path = export.path
      assert File.exists?(path)

      export |> Ecto.Changeset.change(expires_at: past()) |> Repo.update!()

      assert Exports.sweep() == 1
      refute File.exists?(path)

      # The row stays, because it is what the weekly limit is computed from.
      # Deleting it would reset that limit after two days rather than seven.
      assert %Export{state: "expired", path: nil} = Repo.get(Export, export.id)
      assert {:error, {:too_soon, _at}} = Exports.request(account)
    end

    test "leaves a live one alone", %{account: account} do
      {:ok, export} = Exports.request(account)
      Oban.drain_queue(queue: :ingress)

      Exports.sweep()

      assert %Export{} = Repo.get(Export, export.id)
    end
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  defp past, do: DateTime.add(DateTime.utc_now(), -1, :second)

  defp age(export, days) do
    then = DateTime.add(DateTime.utc_now(), -days, :day)

    export |> Ecto.Changeset.change(inserted_at: then) |> Repo.update!()
  end
end
