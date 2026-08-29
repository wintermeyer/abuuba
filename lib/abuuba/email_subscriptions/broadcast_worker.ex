defmodule Abuuba.EmailSubscriptions.BroadcastWorker do
  @moduledoc """
  Writes one message to one account's list, a page at a time.

  ## Why it hands on to itself

  A list is as long as somebody made it. Reading all of it into one job is a
  job that runs out of time on a big list and is retried from the top, which
  means everybody who was already written to hears the same thing twice. So
  each run takes a page, records how far it got on the message row, and queues
  the next page. A job that dies takes at most one page with it.

  The cursor lives on the row rather than in the job's arguments for the same
  reason: Oban retries a job with the arguments it was given, so a cursor in
  the arguments would be the cursor as it was before the page that failed. It
  moves one address at a time, so the worst a retry can repeat is the single
  message that was in flight.

  ## What it will not send

  Anything to an unconfirmed address, and anything at all for an account that
  has since closed its list or been suspended. Somebody who turned the feature
  off between writing a message and it going out has said no in between, and
  the queue is the one place that can still hear it.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  require Logger

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.EmailSubscriptions
  alias Abuuba.EmailSubscriptions.Message
  alias Abuuba.EmailSubscriptions.Notifier
  alias Abuuba.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => id}}) do
    case Repo.get(Message, id) do
      %Message{finished_at: nil} = message -> send_page(message)
      _done_or_gone -> :ok
    end
  end

  defp send_page(message) do
    case Accounts.get_account(message.account_id) do
      %Account{} = account -> send_page(message, account)
      nil -> finish(message)
    end
  end

  defp send_page(message, account) do
    if EmailSubscriptions.open?(account) do
      message.account_id
      |> EmailSubscriptions.confirmed_after(message.sent_through_id)
      |> deliver(message, account)
    else
      finish(message)
    end
  end

  defp deliver([], message, _account), do: finish(message)

  defp deliver(subscriptions, message, account) do
    message = Enum.reduce(subscriptions, message, &deliver_one(&1, &2, account))

    %{"message_id" => message.id}
    |> __MODULE__.new()
    |> Oban.insert!()

    :ok
  end

  # The cursor moves one address at a time rather than once per page, and it
  # moves whether or not the address could be reached. Both halves matter: a
  # page-sized cursor means an adapter that raises halfway makes the retry
  # write to everybody before the failure a second time, and an address the
  # mail server refuses is not a reason to keep the whole list waiting.
  #
  # `recipient_count` counts what was actually accepted, so the number the
  # author is shown is the number of messages that went out rather than the
  # number attempted.
  defp deliver_one(subscription, message, account) do
    delivered? = delivered?(account, subscription, message)

    {:ok, message} =
      message
      |> Message.progress_changeset(%{
        sent_through_id: subscription.id,
        recipient_count: message.recipient_count + if(delivered?, do: 1, else: 0)
      })
      |> Repo.update()

    message
  end

  # An address this server cannot reach must not take the rest of the list with
  # it. Mail servers refuse individual recipients for reasons that have nothing
  # to do with the other forty-nine on the page.
  defp delivered?(account, subscription, message) do
    match?({:ok, _email}, Notifier.deliver_update(account, subscription, message))
  rescue
    error ->
      Logger.warning(
        "email subscription delivery failed for message #{message.id}: " <>
          Exception.message(error)
      )

      false
  end

  defp finish(message) do
    {:ok, _message} =
      message
      |> Message.progress_changeset(%{finished_at: DateTime.utc_now()})
      |> Repo.update()

    :ok
  end
end
