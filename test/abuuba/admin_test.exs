defmodule Abuuba.AdminTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Admin
  alias Abuuba.Moderation.Actions
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Moderation.Domains
  alias Abuuba.Moderation.Reports
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Settings

  setup do
    %{moderator: account_fixture()}
  end

  defp pending_user do
    account = account_fixture()

    user_fixture(%{account_id: account.id, approved: false, confirmed_at: DateTime.utc_now()})
  end

  describe "the dashboard" do
    test "counts what is waiting for somebody", %{moderator: mod} do
      target = account_fixture()
      {:ok, _} = Reports.create(account_fixture(), %{"target_account_id" => target.id})
      {:ok, strike} = Actions.take(mod, target, "silence")
      {:ok, _} = Actions.appeal(target, strike, "I did not.")
      pending_user()

      counts = Admin.pending_counts()

      assert counts.reports == 1
      assert counts.appeals == 1
      assert counts.users == 1
    end

    test "counts nothing when nothing is waiting" do
      counts = Admin.pending_counts()

      assert counts.reports == 0
      assert counts.appeals == 0
      assert counts.users == 0
    end

    test "says what is wrong rather than only what is right" do
      # A dashboard of green ticks nobody reads is worth less than a short list
      # of what needs attention.
      checks = Admin.system_checks()

      assert Enum.all?(checks, &Map.has_key?(&1, :ok?))
      assert Enum.any?(checks, &(&1.key == "database"))
    end

    test "notices an open registration nobody is moderating" do
      :ok = Settings.put_registration_mode("open")

      check = Enum.find(Admin.system_checks(), &(&1.key == "registrations"))

      refute check.ok?
    end

    test "is content with registrations behind approval" do
      :ok = Settings.put_registration_mode("approved")

      check = Enum.find(Admin.system_checks(), &(&1.key == "registrations"))

      assert check.ok?
    end
  end

  describe "finding an account" do
    test "by the start of its username" do
      account = account_fixture(%{username: "findable"})

      assert [found] = Admin.accounts(%{query: "find"})
      assert found.id == account.id
    end

    test "by handle with the domain", %{} do
      account = remote_account_fixture(%{username: "faraway", domain: "other.example"})

      assert [found] = Admin.accounts(%{query: "faraway@other.example"})
      assert found.id == account.id
    end

    test "local only" do
      local = account_fixture()
      remote = remote_account_fixture(%{domain: "other.example"})

      ids = Admin.accounts(%{origin: "local"}) |> Enum.map(& &1.id)

      assert local.id in ids
      refute remote.id in ids
    end

    test "remote only", %{moderator: mod} do
      remote = remote_account_fixture(%{domain: "other.example"})

      ids = Admin.accounts(%{origin: "remote"}) |> Enum.map(& &1.id)

      assert ids == [remote.id]
      refute mod.id in ids
    end

    test "the ones a moderator has acted on", %{moderator: mod} do
      quiet = account_fixture()
      loud = account_fixture()
      {:ok, _} = Actions.take(mod, loud, "silence")

      ids = Admin.accounts(%{status: "silenced"}) |> Enum.map(& &1.id)

      assert loud.id in ids
      refute quiet.id in ids
    end

    test "the ones waiting to be let in" do
      user = pending_user()

      assert [found] = Admin.accounts(%{status: "pending"})
      assert found.id == user.account_id
    end
  end

  describe "the approval queue" do
    test "letting somebody in", %{moderator: mod} do
      user = pending_user()

      assert {:ok, approved} = Admin.approve_user(mod, user)

      assert approved.approved
      assert approved.approved_at
    end

    test "is written down", %{moderator: mod} do
      user = pending_user()

      {:ok, _} = Admin.approve_user(mod, user)

      assert Enum.any?(AuditLog.by_actor(mod), &(&1.action == "user.approve"))
    end

    test "turning somebody away removes the account with it", %{moderator: mod} do
      # A rejected registration that leaves an account behind holds the
      # username against the next person who wants it.
      user = pending_user()
      account_id = user.account_id

      assert :ok = Admin.reject_user(mod, user)

      assert Accounts.get_account(account_id) == nil
      assert Repo.get(Abuuba.Accounts.User, user.id) == nil
    end

    test "refuses to turn away somebody already let in", %{moderator: mod} do
      user = pending_user()
      {:ok, user} = Admin.approve_user(mod, user)

      assert {:error, :already_approved} = Admin.reject_user(mod, user)
    end
  end

  describe "acting on a user" do
    test "changing an email address", %{moderator: mod} do
      user = pending_user()

      assert {:ok, changed} = Admin.change_email(mod, user, "new@example.test")
      assert changed.email == "new@example.test"
    end

    test "refuses one that is not an address", %{moderator: mod} do
      user = pending_user()

      assert {:error, changeset} = Admin.change_email(mod, user, "not an address")
      assert %{email: [_]} = errors_on(changeset)
    end

    test "giving somebody a role", %{moderator: mod} do
      user = pending_user()
      {:ok, role} = Roles.create(%{name: "Helper", position: 10})

      assert {:ok, changed} = Admin.assign_role(mod, user, role)
      assert changed.role_id == role.id

      assert Enum.any?(AuditLog.by_actor(mod), &(&1.action == "user.role"))
    end

    test "and taking it away again", %{moderator: mod} do
      user = pending_user()
      {:ok, role} = Roles.create(%{name: "Helper", position: 10})
      {:ok, user} = Admin.assign_role(mod, user, role)

      assert {:ok, changed} = Admin.assign_role(mod, user, nil)
      assert changed.role_id == nil
    end
  end

  describe "the audit log" do
    test "still reads after the account it was about is gone", %{moderator: mod} do
      # The entry is read when somebody asks what happened, which is most often
      # after the thing it happened to has been deleted.
      target = account_fixture(%{username: "gonesoon"})
      {:ok, _} = Actions.take(mod, target, "silence")

      {:ok, _} = Accounts.delete_account(target)

      assert [entry] = Admin.audit_log(%{})
      assert entry.target_label =~ "gonesoon"
      assert entry.account_handle
    end

    test "still says who did it after they are gone", %{moderator: mod} do
      target = account_fixture()
      {:ok, _} = Actions.take(mod, target, "silence")

      {:ok, _} = Accounts.delete_account(mod)

      assert [entry] = Admin.audit_log(%{})
      assert entry.account_handle == Account.acct(mod)
    end

    test "can be narrowed to one moderator", %{moderator: mod} do
      other = account_fixture()
      {:ok, _} = Actions.take(mod, account_fixture(), "silence")
      {:ok, _} = Actions.take(other, account_fixture(), "silence")

      entries = Admin.audit_log(%{account_id: mod.id})

      assert length(entries) == 1
      assert hd(entries).account_handle == Account.acct(mod)
    end

    test "and to one kind of action", %{moderator: mod} do
      {:ok, _} = Actions.take(mod, account_fixture(), "silence")
      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example"})

      assert [entry] = Admin.audit_log(%{action: "domain_block.create"})
      assert entry.action == "domain_block.create"
    end

    test "newest first, because that is what somebody is looking for", %{moderator: mod} do
      {:ok, _} = Actions.take(mod, account_fixture(), "silence")
      {:ok, _} = Actions.take(mod, account_fixture(), "suspend")

      assert [first, second] = Admin.audit_log(%{})
      assert first.id > second.id
    end
  end

  describe "instance settings" do
    test "reads what is set and what is defaulted" do
      settings = Admin.settings()

      assert settings["site_title"] == "abuuba"
      assert Map.has_key?(settings, "registration_mode")
    end

    test "writes a change and logs it", %{moderator: mod} do
      assert :ok = Admin.put_settings(mod, %{"site_title" => "A Better Name"})

      assert Settings.get("site_title") == "A Better Name"
      assert Enum.any?(AuditLog.by_actor(mod), &(&1.action == "settings.update"))
    end

    test "ignores a key nobody defined", %{moderator: mod} do
      # The form posts what it renders. A key that arrives from somewhere else
      # is either a mistake or somebody trying one, and writing it would let
      # anybody with the settings page put anything in the settings table.
      :ok = Admin.put_settings(mod, %{"site_title" => "Fine", "wallet_key" => "nope"})

      assert Settings.get("wallet_key") == nil
    end

    test "refuses a registration mode nobody defined", %{moderator: mod} do
      :ok = Admin.put_settings(mod, %{"registration_mode" => "shouting"})

      assert Settings.registration_mode() == :approved
    end
  end
end
