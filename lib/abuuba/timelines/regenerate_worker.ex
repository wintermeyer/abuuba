defmodule Abuuba.Timelines.RegenerateWorker do
  @moduledoc """
  Rebuilds a home feed from scratch.

  ## Who needs this

  Somebody coming back after being away long enough that their feed was trimmed
  to nothing, and anybody whose feed is empty for a reason nobody can see. The
  alternative is telling them there is nothing to read, which is both wrong and
  the impression they will leave with.

  ## It is not a fan-out in reverse

  The rule itself is `Abuuba.Timelines.regenerate/1`, which lives next to the
  filtering it has to match. This is the job that runs it in the background;
  the Mastodon import runs the same function in the foreground.
  """

  # Running it once is this option's business rather than the refresh row's. A
  # request queues a rebuild whenever the feed is empty, so without it a client
  # polling every few seconds would queue one per poll.
  #
  # On the whole args, refresh id included, and deliberately not on the account
  # alone. Deduping per account swallows the enqueue for a *new* refresh made
  # after an earlier job completed, and that refresh then sits `running` for
  # its whole day with nothing on its way to finish it — which is how the
  # smoke test found this. Keyed on the refresh, a repeat poll for the same one
  # is dropped and a new one always gets its job, and `discarded` being outside
  # the default states means a rebuild that exhausted its attempts is retried
  # rather than wedged.
  use Oban.Worker, queue: :ingress, max_attempts: 3, unique: [period: 300]

  alias Abuuba.AsyncRefreshes
  alias Abuuba.Timelines

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id} = args}) do
    Timelines.regenerate(account_id)

    # Told last, and told how much is there. A client watching the refresh
    # reloads on `finished`, so finishing before the rows are written would
    # have it reload the empty feed it was already looking at.
    AsyncRefreshes.finish(args["async_refresh_id"],
      result_count: Timelines.home_size(account_id)
    )

    :ok
  end

  @doc """
  Queues a rebuild.

  `refresh` is the id a client is watching, where a request started one. Passed
  through the job rather than looked up by account, because a rebuild queued by
  something other than a waiting client has nobody to tell.
  """
  @spec enqueue(integer(), integer() | nil) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(account_id, refresh_id \\ nil) do
    %{account_id: account_id, async_refresh_id: refresh_id} |> new() |> Oban.insert()
  end
end
