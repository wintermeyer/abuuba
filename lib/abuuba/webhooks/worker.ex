defmodule Abuuba.Webhooks.Worker do
  @moduledoc """
  Posts one event to one webhook.

  Through the ordinary outbound layer, so it inherits the SSRF guards, the
  timeouts and the circuit breaker rather than growing its own set. An admin
  can type a URL, and a URL an admin typed is still a URL from outside the
  program as far as the network is concerned.

  Every attempt is logged, successful or not, because the log exists to answer
  "is this working" and that question needs both answers. A 4xx is not retried:
  the receiver understood and refused, and time does not change that.
  """

  use Oban.Worker, queue: :push, max_attempts: 5

  alias Abuuba.Federation.HTTP
  alias Abuuba.Webhooks
  alias Abuuba.Webhooks.Webhook

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_id" => id} = args, attempt: attempt}) do
    case Webhooks.get(id) do
      # Removed or turned off while the job waited. Not a failure and not
      # something to retry into.
      %Webhook{enabled: true} = webhook -> post(webhook, args, attempt)
      _ -> :ok
    end
  end

  defp post(webhook, %{"event" => event, "payload" => payload}, attempt) do
    body = Jason.encode!(%{"event" => event, "created_at" => timestamp(), "object" => payload})

    headers = [
      {"content-type", "application/json"},
      {"x-hub-signature-256", Webhooks.signature(webhook.secret, body)},
      {"x-abuuba-event", event}
    ]

    webhook.url
    |> HTTP.post_json(body, headers: headers, sign_as: nil)
    |> interpret(webhook, event, attempt)
  end

  defp interpret({:ok, %{status: status}}, webhook, event, attempt)
       when status >= 200 and status < 300 do
    Webhooks.record(webhook, event, status: status, attempt: attempt)

    :ok
  end

  defp interpret({:ok, %{status: status}}, webhook, event, attempt)
       when status >= 400 and status < 500 do
    Webhooks.record(webhook, event, status: status, error: "refused", attempt: attempt)

    # Understood and refused. Sixteen more attempts will be refused too.
    {:cancel, {:refused, status}}
  end

  defp interpret({:ok, %{status: status}}, webhook, event, attempt) do
    Webhooks.record(webhook, event, status: status, error: "server error", attempt: attempt)

    {:error, {:status, status}}
  end

  defp interpret({:error, reason}, webhook, event, attempt) do
    Webhooks.record(webhook, event, error: inspect(reason), attempt: attempt)

    {:error, reason}
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
