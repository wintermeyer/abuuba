defmodule Abuuba.ReportsTest do
  use Abuuba.DataCase, async: true
  use Oban.Testing, repo: Abuuba.Repo

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Moderation.ForwardWorker
  alias Abuuba.Moderation.Report
  alias Abuuba.Moderation.Reports
  alias Abuuba.Notifications
  alias Abuuba.Roles

  setup do
    reporter = account_fixture()
    target = account_fixture()

    %{reporter: reporter, target: target}
  end

  defp moderator do
    {:ok, role} =
      Roles.create(%{
        name: "Moderator #{System.unique_integer([:positive])}",
        position: 10,
        permissions: Roles.mask(["manage_reports"])
      })

    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, _} = Roles.assign(user, role)

    account
  end

  describe "filing one" do
    test "records what it is about", %{reporter: reporter, target: target} do
      assert {:ok, report} =
               Reports.create(reporter, %{
                 "target_account_id" => target.id,
                 "category" => "spam",
                 "comment" => "nothing but links"
               })

      assert report.category == "spam"
      assert report.comment == "nothing but links"
      refute Report.resolved?(report)
    end

    test "keeps the posts it names as evidence", %{reporter: reporter, target: target} do
      status = status_fixture(%{account_id: target.id, text: "the offending post"})

      {:ok, report} =
        Reports.create(reporter, %{
          "target_account_id" => target.id,
          "status_ids" => [status.id]
        })

      assert report.status_ids == [status.id]
    end

    test "drops evidence the reported account did not write", %{
      reporter: reporter,
      target: target
    } do
      # Otherwise a report puts somebody else's posts in front of a moderator
      # as though the reported account had written them.
      somebody_else = status_fixture(%{account_id: account_fixture().id, text: "innocent"})

      {:ok, report} =
        Reports.create(reporter, %{
          "target_account_id" => target.id,
          "status_ids" => [somebody_else.id]
        })

      assert report.status_ids == []
    end

    test "refuses a report against yourself", %{reporter: reporter} do
      assert {:error, changeset} =
               Reports.create(reporter, %{"target_account_id" => reporter.id})

      assert %{target_account_id: [_]} = errors_on(changeset)
    end

    test "refuses a comment longer than the cap", %{reporter: reporter, target: target} do
      long = String.duplicate("a", Report.max_comment() + 1)

      assert {:error, changeset} =
               Reports.create(reporter, %{"target_account_id" => target.id, "comment" => long})

      assert %{comment: [_]} = errors_on(changeset)
    end

    test "records which rules a violation report names", %{reporter: reporter, target: target} do
      {:ok, rule} = Abuuba.Settings.create_rule(%{text: "Be kind", position: 1})

      {:ok, report} =
        Reports.create(reporter, %{
          "target_account_id" => target.id,
          "category" => "violation",
          "rule_ids" => [rule.id]
        })

      assert report.rule_ids == [rule.id]
    end

    test "writes what happened to the log", %{reporter: reporter, target: target} do
      {:ok, report} = Reports.create(reporter, %{"target_account_id" => target.id})

      assert [%{action: "report.create"}] = Reports.history(report)
    end
  end

  describe "telling the moderators" do
    test "tells everybody who handles reports", %{reporter: reporter, target: target} do
      one = moderator()
      two = moderator()

      {:ok, _} = Reports.create(reporter, %{"target_account_id" => target.id})

      assert [_] = Notifications.list(one)
      assert [_] = Notifications.list(two)
    end

    test "tells nobody who does not", %{reporter: reporter, target: target} do
      bystander = account_fixture()
      user_fixture(%{account_id: bystander.id, approved: true, confirmed_at: DateTime.utc_now()})

      {:ok, _} = Reports.create(reporter, %{"target_account_id" => target.id})

      assert Notifications.list(bystander) == []
    end

    test "tells them once about one account, not once per report", %{target: target} do
      # Ten people reporting the same account in a minute is one thing a
      # moderator has to look at, and a notification each turns a brigading
      # incident into a denial of service against the people handling it.
      mod = moderator()

      for _ <- 1..3 do
        {:ok, _} = Reports.create(account_fixture(), %{"target_account_id" => target.id})
      end

      assert length(Notifications.list(mod)) == 1
    end

    test "tells them again once the earlier ones are dealt with", %{
      reporter: reporter,
      target: target
    } do
      mod = moderator()

      {:ok, first} = Reports.create(reporter, %{"target_account_id" => target.id})
      {:ok, _} = Reports.resolve(first, mod)

      Notifications.clear(mod)
      {:ok, _} = Reports.create(account_fixture(), %{"target_account_id" => target.id})

      assert [_] = Notifications.list(mod)
    end
  end

  describe "the queue" do
    setup %{reporter: reporter, target: target} do
      {:ok, report} = Reports.create(reporter, %{"target_account_id" => target.id})

      %{report: report, mod: moderator()}
    end

    test "holds what is unresolved", %{report: report} do
      assert Enum.map(Reports.list(%{resolved: false}), & &1.id) == [report.id]
      assert Reports.open_count() == 1
    end

    test "one can be put in somebody's hands", %{report: report, mod: mod} do
      assert {:ok, assigned} = Reports.assign(report, mod, mod)
      assert assigned.assigned_account_id == mod.id
      assert [_] = Reports.list(%{assigned_account_id: mod.id})
    end

    test "and taken back out of them", %{report: report, mod: mod} do
      {:ok, report} = Reports.assign(report, mod, mod)

      assert {:ok, unassigned} = Reports.assign(report, nil, mod)
      assert unassigned.assigned_account_id == nil
    end

    test "resolving takes it off the queue", %{report: report, mod: mod} do
      assert {:ok, resolved} = Reports.resolve(report, mod)

      assert Report.resolved?(resolved)
      assert resolved.action_taken_by_account_id == mod.id
      assert Reports.list(%{resolved: false}) == []
      assert Reports.open_count() == 0
    end

    test "reopening puts it back", %{report: report, mod: mod} do
      {:ok, report} = Reports.resolve(report, mod)

      assert {:ok, reopened} = Reports.reopen(report, mod)

      refute Report.resolved?(reopened)
      assert Reports.open_count() == 1
    end

    test "every step is in the history, oldest first", %{report: report, mod: mod} do
      {:ok, report} = Reports.assign(report, mod, mod)
      {:ok, report} = Reports.resolve(report, mod)
      {:ok, _} = Reports.reopen(report, mod)

      assert ["report.create", "report.assign", "report.resolve", "report.reopen"] =
               Enum.map(Reports.history(report), & &1.action)
    end

    test "the log says who did it", %{report: report, mod: mod} do
      {:ok, _} = Reports.resolve(report, mod, %{"reason" => "nothing to answer"})

      assert [_create, resolve] = Reports.history(report)
      assert resolve.account_id == mod.id
      assert resolve.details["reason"] == "nothing to answer"
    end

    test "a moderator's own actions can be listed", %{report: report, mod: mod} do
      {:ok, _} = Reports.resolve(report, mod)

      assert [%{action: "report.resolve"}] = AuditLog.by_actor(mod)
    end
  end

  describe "forwarding" do
    test "is queued when the reporter asks", %{reporter: reporter} do
      remote = remote_account_fixture(%{domain: "remote.example"})

      {:ok, report} =
        Reports.create(reporter, %{"target_account_id" => remote.id, "forward" => true})

      assert [job] = all_enqueued(worker: ForwardWorker)
      assert job.args["report_id"] == report.id
    end

    test "is not queued otherwise", %{reporter: reporter} do
      # Forwarding tells the other server who complained, which is not ours to
      # decide on somebody's behalf.
      remote = remote_account_fixture(%{domain: "remote.example"})

      {:ok, _} = Reports.create(reporter, %{"target_account_id" => remote.id})

      assert all_enqueued(worker: ForwardWorker) == []
    end

    test "goes nowhere for one of our own accounts", %{reporter: reporter, target: target} do
      {:ok, report} =
        Reports.create(reporter, %{"target_account_id" => target.id, "forward" => true})

      assert :ok = perform_job(ForwardWorker, %{"report_id" => report.id})
      refute Abuuba.Repo.get(Report, report.id).forwarded
    end

    test "marks the report forwarded once it has gone", %{reporter: reporter} do
      remote =
        remote_account_fixture(%{
          domain: "remote.example",
          inbox_url: "https://remote.example/inbox"
        })

      {:ok, report} =
        Reports.create(reporter, %{"target_account_id" => remote.id, "forward" => true})

      assert :ok = perform_job(ForwardWorker, %{"report_id" => report.id})
      assert Abuuba.Repo.get(Report, report.id).forwarded
    end
  end
end
