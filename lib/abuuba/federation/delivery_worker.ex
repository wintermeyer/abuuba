defmodule Abuuba.Federation.DeliveryWorker do
  @moduledoc """
  One job, one inbox.

  Split per inbox rather than per activity, so that one unreachable server does
  not hold up delivery to every other server on the same post. That is the
  common case rather than a rare one: on any large post at least one peer is
  always down.

  ## What is worth retrying

  A 4xx means the peer understood and refused, and refusing is not something
  time changes. Three are exceptions and they matter: 401 because the
  double-knock in `Abuuba.Federation.DoubleKnock` may still find the other
  signature scheme, 408 because a timeout is not a refusal, and 429 because it
  explicitly means "later".

  Everything else 4xx is permanent, and treating it as retryable would mean
  sixteen attempts at something that was answered correctly the first time.

  ## What a job carries

  The account to sign as, not the key to sign with. A signing key is encrypted
  at rest in `keypairs`, and copying the decrypted PEM into every job would put
  a plaintext copy of it in the queue table, once per destination server, for
  as long as the job lives.
  """

  use Oban.Worker, queue: :push, max_attempts: 16

  alias Abuuba.Accounts
  alias Abuuba.Federation.Availability
  alias Abuuba.Federation.DoubleKnock
  alias Abuuba.Federation.HTTP
  alias Abuuba.Federation.Instances
  alias Abuuba.Federation.Relays
  alias Abuuba.Federation.URIs

  @permanent_except [401, 408, 429]

  # Postgres takes 65535 bind parameters in one statement and Oban does not
  # chunk, so a large enough fan-out would fail the insert outright rather than
  # deliver slowly.
  @insert_chunk 1_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    %{"inbox" => inbox, "activity" => activity} = args

    case URIs.host_of(inbox) do
      nil ->
        # Nowhere to deliver to and nothing a retry can do about it.
        {:cancel, :inbox_without_host}

      domain ->
        if Availability.unavailable?(domain) do
          # Given up on. Skipping rather than retrying is the whole point of
          # tracking availability at all.
          :ok
        else
          deliver(inbox, domain, activity, args, job)
        end
    end
  end

  defp deliver(inbox, domain, activity, args, job) do
    case keypair(args) do
      # Our own key is missing, which no number of retries fixes. Retrying
      # would end in a failure day recorded against the peer's domain for a
      # problem entirely on this side of the connection.
      nil -> {:cancel, :no_signing_key}
      pem -> inbox |> knock(activity, pem, args) |> note(inbox) |> interpret(domain, job)
    end
  end

  # A relay's own account of how it is going, so an admin can tell "failing
  # quietly" apart from "nobody has posted yet" without reading logs. A no-op
  # for every inbox that is not a relay's, which is nearly all of them.
  defp note({:ok, %{status: status}} = result, inbox) when status in 200..299 do
    Relays.record_success(inbox)

    result
  end

  defp note({:ok, %{status: status}} = result, inbox) do
    Relays.record_failure(inbox, {:status, status})

    result
  end

  defp note({:error, reason} = result, inbox) do
    Relays.record_failure(inbox, reason)

    result
  end

  defp knock(inbox, activity, private_key, args) do
    DoubleKnock.deliver(
      [
        method: :post,
        url: inbox,
        body: Jason.encode!(activity),
        key_id: args["key_id"],
        private_key: private_key,
        headers: extra_headers(args)
      ],
      fn url, headers, body -> HTTP.post_json(url, body, headers: headers, sign_as: nil) end
    )
  end

  defp keypair(%{"account_id" => account_id}) when is_integer(account_id) do
    case Accounts.active_keypair(account_id) do
      nil -> nil
      keypair -> keypair.private_key
    end
  end

  defp keypair(_args), do: nil

  defp interpret({:ok, %{status: status}}, domain, _job) when status in 200..299 do
    Availability.record_success(domain)

    :ok
  end

  defp interpret({:ok, %{status: status}}, _domain, _job)
       when status >= 400 and status < 500 and status not in @permanent_except do
    # Understood and refused. Time does not change that answer, so this is
    # cancelled rather than retried sixteen times.
    {:cancel, {:refused, status}}
  end

  defp interpret({:ok, %{status: status}}, domain, job) do
    maybe_give_up(domain, job)
    Instances.record_error(domain, {:status, status})

    {:error, {:status, status}}
  end

  defp interpret({:error, reason}, domain, job) do
    maybe_give_up(domain, job)
    Instances.record_error(domain, reason)

    {:error, reason}
  end

  # Only when the retries are exhausted. Recording a failure day on the first
  # attempt would mark a server dead for a single dropped packet.
  defp maybe_give_up(domain, %Oban.Job{attempt: attempt, max_attempts: max})
       when attempt >= max do
    Availability.record_failure(domain)
  end

  defp maybe_give_up(_domain, _job), do: :ok

  # Polynomial rather than exponential, with jitter. Exponential reaches days
  # between attempts inside sixteen tries, which is longer than anybody waits
  # for a post to arrive; the jitter is so that a thousand deliveries queued by
  # one popular post do not all retry in the same second and knock over a
  # server that was only briefly busy.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    base = trunc(:math.pow(attempt, 4)) + 15
    jitter = :rand.uniform(max(div(base, 4), 1))

    base + jitter
  end

  @doc """
  Queues one delivery per inbox.

  `:headers` maps a destination domain to the extra headers that server's
  delivery carries. Whatever those headers mean is the caller's business; this
  sends them.
  """
  @spec enqueue([String.t()], map(), keyword()) :: :ok
  def enqueue(inboxes, activity, opts) do
    account_id = Keyword.fetch!(opts, :account_id)
    key_id = Keyword.fetch!(opts, :key_id)
    headers = Keyword.get(opts, :headers, %{})

    inboxes
    |> Enum.map(fn inbox ->
      new(%{
        inbox: inbox,
        activity: activity,
        account_id: account_id,
        key_id: key_id,
        headers: Map.get(headers, URIs.host_of(inbox), %{})
      })
    end)
    |> Enum.chunk_every(@insert_chunk)
    |> Enum.each(&Oban.insert_all/1)

    :ok
  end

  # Carried as a map because job args are JSON and a tuple is not.
  defp extra_headers(%{"headers" => headers}) when is_map(headers), do: Map.to_list(headers)
  defp extra_headers(_args), do: []
end
