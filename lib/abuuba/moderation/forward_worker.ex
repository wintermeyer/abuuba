defmodule Abuuba.Moderation.ForwardWorker do
  @moduledoc """
  Sends a report on to the server that hosts the account it is about.

  ## Why it goes at all

  A report about somebody on another server names an account this one cannot
  suspend. Only their own server can act, and if nobody tells them they never
  learn there was a problem.

  ## Why it is opt-in

  Forwarding tells that server who complained. That is a real cost to the
  reporter, borne on another server under somebody else's moderation, and it is
  not ours to decide on their behalf. So it happens only when they ask.

  ## Who it reaches

  The reported account's own server, and the servers hosting anybody being
  replied to in the evidence. A reply is a conversation with two sides, and the
  server on the other side is the one that can see the rest of it.
  """

  use Oban.Worker, queue: :push, max_attempts: 8

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Delivery
  alias Abuuba.Federation.InstanceActor
  alias Abuuba.Federation.Serializer
  alias Abuuba.Moderation.Report
  alias Abuuba.Repo
  alias Abuuba.Statuses.Status

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"report_id" => report_id}}) do
    case Repo.get(Report, report_id) do
      nil -> :ok
      report -> forward(report)
    end
  end

  @doc """
  Queues a forward.
  """
  @spec enqueue(integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(report_id) do
    %{report_id: report_id} |> new() |> Oban.insert()
  end

  defp forward(%Report{} = report) do
    target = Accounts.get_account(report.target_account_id)

    # A report about one of our own accounts has nowhere to go: we are the
    # server that can act on it.
    if is_nil(target) or is_nil(target.domain) do
      :ok
    else
      deliver(report, target)
    end
  end

  defp deliver(report, target) do
    # Signed by the server rather than by the person who complained. Naming the
    # reporter would tell the reported account's server, and through it the
    # reported account, who objected to them.
    actor = InstanceActor.fetch!()
    evidence = Repo.all(from(s in Status, where: s.id in ^report.status_ids))

    Delivery.deliver_to(
      inboxes(report, target),
      Serializer.flag(target, evidence, report.comment, report.id),
      actor
    )

    report |> Ecto.Changeset.change(forwarded: true) |> Repo.update()

    :ok
  end

  # The reported account's server, and whoever is on the other side of a reply
  # in the evidence: a reply is a conversation, and the server hosting the
  # other half is the one that can see the rest of it.
  defp inboxes(report, target) do
    reply_targets =
      from(s in Status,
        where: s.id in ^report.status_ids and not is_nil(s.in_reply_to_account_id),
        select: s.in_reply_to_account_id
      )
      |> Repo.all()
      |> Enum.flat_map(&List.wrap(Accounts.get_account(&1)))
      |> Enum.reject(&is_nil(&1.domain))

    [target | reply_targets]
    |> Enum.map(&inbox_of/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp inbox_of(%Account{shared_inbox_url: url}) when is_binary(url) and url != "", do: url
  defp inbox_of(%Account{inbox_url: url}) when is_binary(url) and url != "", do: url
  defp inbox_of(_account), do: nil
end
