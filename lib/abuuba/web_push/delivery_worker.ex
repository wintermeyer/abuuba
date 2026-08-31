defmodule Abuuba.WebPush.DeliveryWorker do
  @moduledoc """
  Getting one encrypted notification to one push service.

  ## A 4xx destroys the subscription

  It means the endpoint is gone, and it does not come back: a browser renews a
  subscription rather than repairing one. Retrying is how a server ends up
  pushing to thousands of dead endpoints forever, and every one of those is a
  request somebody else's service has to refuse. 408 and 429 are the
  exceptions, because they mean "not now" rather than "not ever".

  ## TTL

  Forty-eight hours. A push service holds a message for an offline device and
  drops it after that, which is the right shape for a notification: somebody
  coming back after three days does not want their phone to buzz forty times
  for things they have already read in the app.
  """

  use Oban.Worker, queue: :push, max_attempts: 5

  require Logger

  alias Abuuba.Federation.HTTP
  alias Abuuba.Notifications
  alias Abuuba.Notifications.Notification
  alias Abuuba.Repo
  alias Abuuba.WebPush
  alias Abuuba.WebPush.Encryption
  alias Abuuba.WebPush.Subscription
  alias Abuuba.WebPush.VAPID

  @ttl_seconds 48 * 60 * 60
  @retryable [408, 429]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => sub_id, "notification_id" => note_id}}) do
    with %Subscription{} = subscription <- Repo.get(Subscription, sub_id),
         notification when not is_nil(notification) <- get_notification(note_id) do
      deliver(subscription, notification)
    else
      # Either was deleted while queued, which is ordinary: somebody revoked
      # the app, or dismissed the notification before their phone woke up.
      _ -> :ok
    end
  end

  defp deliver(subscription, notification) do
    payload = WebPush.payload(notification, subscription, "")

    with {:ok, authorization} <- VAPID.authorization(subscription.endpoint),
         {:ok, sealed} <-
           Encryption.encrypt(
             Jason.encode!(payload),
             subscription.key_p256dh,
             subscription.key_auth,
             subscription.encoding
           ) do
      headers =
        [
          {"authorization", authorization},
          {"ttl", Integer.to_string(@ttl_seconds)},
          {"urgency", "normal"}
        ] ++ sealed.headers

      subscription.endpoint
      |> post(sealed.body, headers)
      |> interpret(subscription)
    else
      {:error, :not_configured} ->
        # Nothing to sign with. Cancelled rather than retried, because a
        # missing key is a configuration problem that a retry cannot fix.
        {:cancel, :vapid_not_configured}

      {:error, reason} ->
        {:cancel, reason}
    end
  end

  defp interpret({:ok, status}, _subscription) when status in 200..299, do: :ok

  defp interpret({:ok, status}, _subscription) when status in @retryable do
    {:error, {:status, status}}
  end

  defp interpret({:ok, status}, subscription) when status >= 400 and status < 500 do
    # Gone, and it will not come back. Left in place it would be pushed to on
    # every notification for the rest of the server's life.
    Logger.info("push endpoint refused with #{status}; forgetting the subscription")

    WebPush.unsubscribe(subscription)

    {:cancel, {:gone, status}}
  end

  defp interpret({:ok, status}, _subscription), do: {:error, {:status, status}}
  defp interpret({:error, reason}, _subscription), do: {:error, reason}

  defp post(url, body, headers) do
    HTTP.post_json(url, body, headers: headers, sign_as: nil)
  end

  # Through the reader's own door, not a bare fetch. A push is queued the
  # moment a notification is written and runs later, and "later" is long
  # enough to block somebody in: the job would then ring a phone with the
  # blocked account's name in the title, which is the one copy of a
  # notification that arrives somewhere no list can filter it.
  defp get_notification(id) do
    case Repo.get(Notification, id) do
      nil ->
        nil

      %Notification{} = notification ->
        Notifications.get(notification.account_id, notification.id)
    end
  end

  @doc """
  Queues a push for every device that asked about this notification.
  """
  @spec enqueue(Notification.t()) :: :ok
  def enqueue(notification) do
    notification
    |> WebPush.subscriptions_for()
    |> Enum.each(fn subscription ->
      %{subscription_id: subscription.id, notification_id: notification.id}
      |> new()
      |> Oban.insert()
    end)

    :ok
  end
end
