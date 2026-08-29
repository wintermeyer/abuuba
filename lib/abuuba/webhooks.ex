defmodule Abuuba.Webhooks do
  @moduledoc """
  Telling another system that something happened here.

  What an admin builds a moderation queue, an alert or a spreadsheet on. The
  events are the ones a moderator cares about — an account arrived, a report
  came in — so what is usually listening is a moderation tool rather than a
  general integration.

  ## Off when created

  A webhook is added and then turned on, so a URL typed wrong can be corrected
  before this server starts posting somebody's reports to it.

  ## Signed, and the secret is shown once

  Every delivery carries an HMAC of the exact body under the webhook's secret,
  so the receiver can tell a real delivery from anything else that can reach
  its URL — the URL is not a secret and should not have to be one. The secret
  is shown when it is created and when it is rotated, and never again: a secret
  that stays readable on a page is a secret that leaks with the first
  screenshot of that page.

  ## The delivery log is not optional

  A webhook that has quietly stopped working looks exactly like a server where
  nothing has happened. An admin who cannot tell those apart finds out weeks
  later that the queue they were watching was empty because the pipe was
  broken, not because nobody reported anything.
  """

  import Ecto.Query

  alias Abuuba.Repo
  alias Abuuba.Webhooks.Delivery
  alias Abuuba.Webhooks.Webhook
  alias Abuuba.Webhooks.Worker

  # Enough that the log answers "is it working" and "when did it stop", and
  # little enough that it is not an archive of everything this server ever did.
  @keep_days 7
  @log_limit 20

  @doc """
  Every webhook, oldest first.
  """
  @spec list() :: [Webhook.t()]
  def list, do: Webhook |> order_by([w], asc: w.id) |> Repo.all()

  @doc """
  One by id, or `nil`.
  """
  @spec get(term()) :: Webhook.t() | nil
  def get(id) do
    case Integer.parse(to_string(id)) do
      {parsed, ""} -> Repo.get(Webhook, parsed)
      _ -> nil
    end
  end

  @doc """
  Adds one, turned off, with a fresh secret.
  """
  @spec create(map()) :: {:ok, Webhook.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("secret", new_secret())
      |> Map.put("enabled", false)

    %Webhook{} |> Webhook.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Changes the URL or the events.

  Not the secret and not the enabled flag: both have their own function,
  because both are decisions rather than edits.
  """
  @spec update(Webhook.t(), map()) :: {:ok, Webhook.t()} | {:error, Ecto.Changeset.t()}
  def update(%Webhook{} = webhook, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    webhook |> Webhook.changeset(Map.take(attrs, ["url", "events"])) |> Repo.update()
  end

  @doc """
  Turns one on or off.
  """
  @spec set_enabled(Webhook.t(), boolean()) :: {:ok, Webhook.t()} | {:error, Ecto.Changeset.t()}
  def set_enabled(%Webhook{} = webhook, enabled?) do
    webhook |> Ecto.Changeset.change(enabled: enabled?) |> Repo.update()
  end

  @doc """
  Gives one a new secret and returns it.

  The old one stops working immediately, which is the point: rotation exists
  for a secret somebody believes is out, and a grace period would keep whoever
  has it working for the length of the grace period.
  """
  @spec rotate_secret(Webhook.t()) :: {:ok, Webhook.t()} | {:error, Ecto.Changeset.t()}
  def rotate_secret(%Webhook{} = webhook) do
    webhook |> Ecto.Changeset.change(secret: new_secret()) |> Repo.update()
  end

  @doc """
  Removes one.
  """
  @spec delete(Webhook.t()) :: {:ok, Webhook.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Webhook{} = webhook), do: Repo.delete(webhook, stale_error_field: :id)

  @doc """
  Queues one event to every webhook that asked for it.

  Nothing here talks to the network. The caller is usually inside a transaction
  that has just written the thing being announced, and a webhook receiver
  taking four seconds to answer must not be four seconds that transaction is
  open.
  """
  @spec announce(String.t(), map()) :: :ok
  def announce(event, payload) do
    event
    |> subscribers()
    |> Enum.each(fn webhook ->
      %{webhook_id: webhook.id, event: event, payload: payload}
      |> Worker.new()
      |> Oban.insert()
    end)

    :ok
  end

  @doc """
  The enabled webhooks that asked for one event.
  """
  @spec subscribers(String.t()) :: [Webhook.t()]
  def subscribers(event) do
    Webhook
    |> where([w], w.enabled and ^event in w.events)
    |> Repo.all()
  end

  @doc """
  Records one attempt.
  """
  @spec record(Webhook.t() | integer(), String.t(), keyword()) :: :ok
  def record(%Webhook{id: id}, event, opts), do: record(id, event, opts)

  def record(webhook_id, event, opts) do
    attrs = %{
      webhook_id: webhook_id,
      event: event,
      status: Keyword.get(opts, :status),
      error: Keyword.get(opts, :error),
      attempt: Keyword.get(opts, :attempt, 1)
    }

    %Delivery{} |> Delivery.changeset(attrs) |> Repo.insert()

    :ok
  rescue
    # A log that could not be written must not be why a delivery is retried.
    _error -> :ok
  end

  @doc """
  The recent attempts against one webhook, newest first.
  """
  @spec deliveries(Webhook.t() | integer(), pos_integer()) :: [Delivery.t()]
  def deliveries(webhook, limit \\ @log_limit)
  def deliveries(%Webhook{id: id}, limit), do: deliveries(id, limit)

  def deliveries(webhook_id, limit) do
    Delivery
    |> where([d], d.webhook_id == ^webhook_id)
    |> order_by([d], desc: d.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  The signature a receiver checks.

  Over the exact bytes that were sent rather than over anything re-encoded: a
  signature computed from a re-serialised body is a signature that stops
  matching the day a key order changes.
  """
  @spec signature(String.t(), String.t()) :: String.t()
  def signature(secret, body) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  @doc """
  How long the delivery log is kept, in days.
  """
  @spec keep_days() :: pos_integer()
  def keep_days, do: @keep_days

  @doc """
  Deletes log rows past their day.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    cutoff = DateTime.add(DateTime.utc_now(), -@keep_days * 86_400, :second)

    {deleted, _} = Delivery |> where([d], d.inserted_at < ^cutoff) |> Repo.delete_all()

    deleted
  end

  defp new_secret, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
