defmodule Abuuba.Statuses.PollExpiry do
  @moduledoc """
  Telling people a poll has closed.

  ## Who is told

  Its author, and everybody who voted in it. A poll is the one kind of post
  whose point arrives after the post does: somebody who voted has asked a
  question and is waiting for the answer, and without this they only find out
  by going back to look.

  Both halves matter for a poll from another server too. Their author is their
  server's business, but a person here who voted in it is ours.

  ## Once

  A worker that looks for closed polls every minute would tell everybody again
  on the next minute and every minute after that, so a poll records when it was
  announced. Null means not yet, and it is what the worker reads.

  A poll with no expiry never closes and is never announced, which is what a
  peer that sends one without an end time is saying about it.
  """

  import Ecto.Query

  alias Abuuba.Notifications
  alias Abuuba.Repo
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.PollVote
  alias Abuuba.Statuses.Status

  # A ceiling per run. A server coming back after a long outage has a backlog
  # of closed polls, and telling everybody about a thousand of them in one
  # transaction is a worse first minute than telling them over ten.
  @per_run 200

  @doc """
  Announces every poll that has closed since the last run.

  `now` is a parameter so a test can name a moment rather than wait for one.
  """
  @spec run(DateTime.t()) :: {:ok, non_neg_integer()}
  def run(now \\ DateTime.utc_now()) do
    closed = Repo.all(due(now))

    Enum.each(closed, &announce/1)

    {:ok, length(closed)}
  end

  defp due(now) do
    Poll
    |> join(:inner, [p], s in Status, on: s.id == p.status_id)
    |> where([p], is_nil(p.notified_at) and not is_nil(p.expires_at) and p.expires_at <= ^now)
    # A poll on a post that has been deleted is a question nobody can go back
    # and read the answer to.
    |> where([_p, s], is_nil(s.deleted_at))
    |> order_by([p], asc: p.expires_at)
    |> limit(@per_run)
    |> select([p], p)
  end

  defp announce(%Poll{} = poll) do
    # Stamped first. Told twice is worse than told late: a failure between the
    # two leaves a poll nobody was told about, which the next run cannot tell
    # apart from one nobody has voted in -- but a failure the other way round
    # tells everybody again every minute until somebody notices.
    {1, _} =
      Poll
      |> where([p], p.id == ^poll.id and is_nil(p.notified_at))
      |> Repo.update_all(set: [notified_at: DateTime.utc_now()])

    poll
    |> audience()
    |> Enum.each(&Notifications.notify(&1, poll.account_id, "poll", status_id: poll.status_id))
  end

  # The author and the voters, each once. `notify/4` refuses to tell somebody
  # about their own action, so an author who voted in their own poll is told
  # about the closing and not about the vote.
  defp audience(%Poll{} = poll) do
    voters =
      PollVote
      |> where([v], v.poll_id == ^poll.id)
      |> distinct(true)
      |> select([v], v.account_id)
      |> Repo.all()

    Enum.uniq([poll.account_id | voters])
  end
end
