defmodule Abuuba.EmailSubscriptions.ConfirmationWorker do
  @moduledoc """
  Sends the one message an unconfirmed address is allowed to receive.

  A job rather than a call inside the request, for two reasons. An SMTP round
  trip would park an unauthenticated request process on somebody else's
  network; and it would make submitting an address that is already confirmed
  measurably quicker than submitting one that is not, which is exactly the
  difference `Abuuba.EmailSubscriptions` refuses to tell anybody.

  Sends nothing for a row that has confirmed or been removed in the meantime.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  alias Abuuba.Accounts
  alias Abuuba.EmailSubscriptions.Notifier
  alias Abuuba.EmailSubscriptions.Subscription
  alias Abuuba.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => id}}) do
    case Repo.get(Subscription, id) do
      %Subscription{confirmed_at: nil} = subscription ->
        subscription.account_id
        |> Accounts.get_account()
        |> Notifier.deliver_confirmation(subscription)

        :ok

      _ ->
        :ok
    end
  end
end
