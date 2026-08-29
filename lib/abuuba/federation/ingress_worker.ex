defmodule Abuuba.Federation.IngressWorker do
  @moduledoc """
  Does the work an inbox POST asked for, after the request has been answered.

  The request is answered with 202 before any of this runs, and that is not an
  optimisation. A sender is waiting on the socket, and resolving an actor or a
  thread means requests of our own to servers that may be slow or down. Doing
  that inline would make our inbox as slow as the slowest server we depend on,
  and a sender that times out retries, which makes it worse.

  Retries are Oban's. What matters here is that a handler run twice is the same
  as a handler run once, because at-least-once delivery is what both the
  network and the queue provide.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 5

  alias Abuuba.Federation.Handlers
  alias Abuuba.Federation.Inbox

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"activity" => activity} = args}) do
    cond do
      Inbox.no_op?(activity) -> :ok
      not Inbox.relevant?(activity) -> :ok
      true -> Handlers.handle(activity, actor_uri: args["actor_uri"])
    end
  end

  @doc """
  Queues an activity for processing.
  """
  @spec enqueue(map(), String.t() | nil) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(activity, actor_uri) do
    %{activity: activity, actor_uri: actor_uri}
    |> new()
    |> Oban.insert()
  end
end
