defmodule Abuuba.Moderation.Reports do
  @moduledoc """
  Filing reports, and the queue moderators work through.

  ## Nothing happens automatically

  A report is somebody's opinion. Filing one notifies the moderators and puts a
  row in a queue; it does not hide, suspend or delete anything. Anything else
  would make the report button a weapon.

  ## Moderators are told once, not once per report

  Ten people reporting the same account in the same minute is one thing a
  moderator has to look at. So a report against somebody who already has an
  open report notifies nobody again: the queue entry is there, and a
  notification per report turns a brigading incident into a denial of service
  against the people who have to handle it.

  ## Forwarding is asked for, never assumed

  A report about a remote account can be sent on to the server that hosts them,
  because they are the only ones who can act on it. That also tells that server
  who complained, which is not ours to decide on somebody's behalf, so it
  happens only when the reporter asks.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.ActionLimits
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Moderation.ForwardWorker
  alias Abuuba.Moderation.Report
  alias Abuuba.Notifications
  alias Abuuba.Pagination
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Status
  alias Abuuba.Webhooks

  @doc """
  Files a report.

  The evidence is narrowed to posts the target actually wrote: a report naming
  somebody else's posts would put them in front of a moderator as though the
  reported account had written them.
  """
  @spec create(Account.t() | nil, map()) ::
          {:ok, Report.t()} | {:error, :rate_limited | Ecto.Changeset.t()}
  def create(reporter, attrs) do
    attrs = normalise(attrs)

    with :ok <- within_limit(reporter),
         {:ok, report} <- insert(reporter, attrs) do
      AuditLog.record(reporter, "report.create", :report, report.id, %{
        "category" => report.category
      })

      notify_moderators(report)
      maybe_forward(report, attrs)

      Webhooks.announce("report.created", %{
        "id" => to_string(report.id),
        "category" => report.category,
        "account_id" => to_string(report.target_account_id),
        "created_at" => DateTime.to_iso8601(report.inserted_at)
      })

      {:ok, report}
    end
  end

  @doc """
  The queue. Unresolved first unless asked otherwise, newest first.
  """
  @spec list(map()) :: [Report.t()]
  def list(page \\ %{}) do
    Report
    |> resolution_filter(Map.get(page, :resolved))
    |> assignment_filter(Map.get(page, :assigned_account_id))
    |> Pagination.window(Map.put_new(page, :limit, 40))
    |> Repo.all()
    |> Pagination.reading_order(page)
  end

  @doc """
  One report, or `nil`.
  """
  @spec get(integer() | String.t()) :: Report.t() | nil
  def get(id) do
    case Snowflake.cast(id) do
      {:ok, id} -> Repo.get(Report, id)
      _ -> nil
    end
  end

  @doc """
  How many are waiting, which is what a dashboard badge shows.
  """
  @spec open_count() :: non_neg_integer()
  def open_count do
    Report |> where([r], is_nil(r.action_taken_at)) |> Repo.aggregate(:count)
  end

  @doc """
  Puts a report in one moderator's hands, so two do not do the same work.
  """
  @spec assign(Report.t(), Account.t() | nil, Account.t()) ::
          {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
  def assign(%Report{} = report, assignee, actor) do
    with {:ok, updated} <- change_report(report, %{assigned_account_id: id_of(assignee)}) do
      AuditLog.record(actor, action_for(assignee), :report, report.id, %{
        "assignee_id" => id_of(assignee)
      })

      {:ok, updated}
    end
  end

  @doc """
  Marks a report dealt with.

  Whatever was decided, including deciding nothing was needed: a queue where
  "no action" cannot be recorded is a queue that never empties.
  """
  @spec resolve(Report.t(), Account.t(), map()) ::
          {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
  def resolve(%Report{} = report, actor, details \\ %{}) do
    with {:ok, updated} <-
           change_report(report, %{
             action_taken_at: DateTime.utc_now(),
             action_taken_by_account_id: id_of(actor)
           }) do
      AuditLog.record(actor, "report.resolve", :report, report.id, details)

      {:ok, updated}
    end
  end

  @doc """
  Corrects what a report says it is about.

  A moderator reading a report filed under "other" that is plainly about a rule
  can say so, and the next person to open it sees the right thing. Only the
  category and the rules: the comment is the reporter's own words and is not a
  moderator's to rewrite.
  """
  @spec update(Report.t(), Account.t(), map()) ::
          {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
  def update(%Report{} = report, actor, attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.take(~w(category rule_ids))

    with {:ok, updated} <- report |> Report.correction_changeset(attrs) |> Repo.update() do
      AuditLog.record(actor, "report.update", :report, report.id, %{
        "category" => updated.category
      })

      {:ok, updated}
    end
  end

  @doc """
  Puts a resolved report back in the queue.
  """
  @spec reopen(Report.t(), Account.t()) :: {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
  def reopen(%Report{} = report, actor) do
    with {:ok, updated} <-
           change_report(report, %{action_taken_at: nil, action_taken_by_account_id: nil}) do
      AuditLog.record(actor, "report.reopen", :report, report.id)

      {:ok, updated}
    end
  end

  @doc """
  What has happened to one report, oldest first.
  """
  @spec history(Report.t() | integer()) :: [map()]
  def history(%Report{id: id}), do: history(id)
  def history(report_id), do: AuditLog.for_target(:report, report_id)

  @doc """
  Whether anybody else has an open report against the same account.

  What the notification dedup asks, and what a moderator wants to know before
  reading the tenth report of the morning.
  """
  @spec open_against?(Account.t() | integer(), integer() | nil) :: boolean()
  def open_against?(target, except_id \\ nil)
  def open_against?(%Account{id: id}, except_id), do: open_against?(id, except_id)

  def open_against?(target_id, except_id) do
    Report
    |> where([r], r.target_account_id == ^target_id and is_nil(r.action_taken_at))
    |> exclude_id(except_id)
    |> Repo.exists?()
  end

  ## Filing

  defp insert(reporter, attrs) do
    %Report{}
    |> Report.changeset(
      attrs
      |> Map.put("account_id", id_of(reporter))
      |> Map.put("status_ids", evidence(attrs))
    )
    |> Repo.insert()
  end

  # Only posts the reported account actually wrote. A report naming somebody
  # else's posts would put those in front of a moderator as though the reported
  # account had written them.
  defp evidence(attrs) do
    target_id = attrs["target_account_id"]
    ids = attrs |> Map.get("status_ids", []) |> List.wrap() |> Enum.flat_map(&numeric_list/1)

    if ids == [] or is_nil(target_id) do
      []
    else
      Status
      |> where([s], s.id in ^ids and s.account_id == ^target_id)
      |> select([s], s.id)
      |> Repo.all()
    end
  end

  defp within_limit(nil), do: :ok

  defp within_limit(%Account{} = reporter) do
    case ActionLimits.take(reporter, :reports) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  # Once per account under complaint, not once per report. Ten people reporting
  # the same account in the same minute is one thing a moderator has to look
  # at, and a notification each turns a brigading incident into a denial of
  # service against the people handling it.
  defp notify_moderators(%Report{} = report) do
    if open_against?(report.target_account_id, report.id) do
      :ok
    else
      Enum.each(moderators(), fn account_id ->
        Notifications.notify(account_id, report.target_account_id, "admin.report")
      end)
    end
  end

  defp moderators do
    from(u in "users",
      join: r in "user_roles",
      on: r.id == u.role_id,
      select: u.account_id
    )
    |> Repo.all()
    |> Enum.filter(&can_handle?/1)
  end

  defp can_handle?(account_id) do
    case Repo.get_by(Abuuba.Accounts.User, account_id: account_id) do
      nil -> false
      user -> Roles.can?(user, "manage_reports")
    end
  end

  # Only for a remote account, and only when asked. Forwarding tells the other
  # server who complained, which is not ours to decide on somebody's behalf.
  defp maybe_forward(%Report{} = report, attrs) do
    if attrs["forward"] == true do
      ForwardWorker.enqueue(report.id)
    end

    :ok
  end

  ## Plumbing

  # Announced from the one place every change to a report goes through, rather
  # than from each of resolve, reopen, assign and update: four call sites is
  # four chances for the fifth one to be forgotten.
  defp announce_update(%Report{} = report) do
    Webhooks.announce("report.updated", %{
      "id" => to_string(report.id),
      "category" => report.category,
      "account_id" => to_string(report.target_account_id),
      "action_taken" => not is_nil(report.action_taken_at)
    })

    report
  end

  defp change_report(report, attrs) do
    with {:ok, changed} <- report |> Report.resolution_changeset(attrs) |> Repo.update() do
      {:ok, announce_update(changed)}
    end
  end

  defp action_for(nil), do: "report.unassign"
  defp action_for(_assignee), do: "report.assign"

  defp resolution_filter(query, true), do: where(query, [r], not is_nil(r.action_taken_at))
  defp resolution_filter(query, false), do: where(query, [r], is_nil(r.action_taken_at))
  defp resolution_filter(query, _any), do: query

  defp assignment_filter(query, nil), do: query
  defp assignment_filter(query, id), do: where(query, [r], r.assigned_account_id == ^id)

  defp exclude_id(query, nil), do: query
  defp exclude_id(query, id), do: where(query, [r], r.id != ^id)

  defp normalise(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  defp id_of(nil), do: nil
  defp id_of(%Account{id: id}), do: id
  defp id_of(id) when is_integer(id), do: id

  defp numeric_list(value) do
    case Snowflake.cast(value) do
      {:ok, id} -> [id]
      _ -> []
    end
  end
end
