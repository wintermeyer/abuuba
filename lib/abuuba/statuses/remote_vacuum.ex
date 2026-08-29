defmodule Abuuba.Statuses.RemoteVacuum do
  @moduledoc """
  Drops other servers' posts once they are old enough, keeping the ones
  somebody here did something with.

  ## Why this exists

  Media is a cache with a vacuum of its own; the rows behind it are not, and on
  a server with a relay or a few thousand follows out they are what fills the
  disk. Nothing deleted them, ever.

  ## What is kept, and why it is not what upstream keeps

  The reference implementation deletes every remote post past the cutoff and
  lets the foreign keys take the rest: somebody's bookmark list quietly loses
  entries, and their boost of that post disappears from their own profile.

  This server has twice decided the other way -- a picture swept off the disk
  still refetches when a reader opens the post, and an emoji taken out of the
  picker still renders where somebody already used it -- so a post is kept when
  anybody here:

    * favourited it, bookmarked it or pinned it
    * boosted it or quoted it
    * replied to it
    * was mentioned in it

  The last is not about keeping. A mention is somebody's notification, and
  deleting the post behind it leaves them a notification about nothing.

  Boosts and replies are checked as "by a local account" rather than "by
  anybody", because a remote reply to a remote post is as disposable as the
  post itself and keeping either would keep whole foreign threads for ever.

  ## Off unless somebody chose a number

  Zero keeps everything, which is the default. A server discarding a year of
  other people's posts because a default said so is exactly the surprise this
  cannot afford to be.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Media
  alias Abuuba.Media.Attachment
  alias Abuuba.Repo
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Bookmark
  alias Abuuba.Statuses.Favourite
  alias Abuuba.Statuses.Mention
  alias Abuuba.Statuses.Pin
  alias Abuuba.Statuses.Status

  # One run's ceiling. A first run on a server that has never swept would
  # otherwise be a single statement against millions of rows, and the ceiling
  # means the backlog clears over a few nights instead of one long lock.
  @per_run 5_000
  @batch 500

  @doc """
  Deletes remote posts older than `days`, in batches, and answers how many
  went.

  `now` is a parameter so a test can name a moment rather than wait for one.
  """
  @spec run(integer(), DateTime.t()) :: {:ok, non_neg_integer()}
  def run(days, now \\ DateTime.utc_now())

  def run(days, _now) when not is_integer(days) or days <= 0, do: {:ok, 0}

  def run(days, now) do
    cutoff = Snowflake.id_at(DateTime.add(now, -days, :day))

    {:ok, sweep(cutoff, 0)}
  end

  defp sweep(_cutoff, deleted) when deleted >= @per_run, do: deleted

  defp sweep(cutoff, deleted) do
    case Repo.all(doomed(cutoff)) do
      [] ->
        deleted

      ids ->
        # The files first. The attachment rows go with the status through the
        # foreign key, and a row deleted without its bytes leaves bytes nothing
        # can ever name again.
        drop_files(ids)

        {count, _} = Repo.delete_all(from(s in Status, where: s.id in ^ids))

        sweep(cutoff, deleted + count)
    end
  end

  defp drop_files(status_ids) do
    Attachment
    |> where([a], a.status_id in ^status_ids)
    |> Repo.all()
    |> Enum.each(&Media.drop_stored_files/1)
  end

  defp doomed(cutoff) do
    from(s in Status, as: :vacuum)
    |> where([s], s.id < ^cutoff and not s.local)
    |> where([s], ^kept_by_nobody())
    |> limit(@batch)
    |> select([s], s.id)
  end

  # Every reason to keep one, as `NOT EXISTS` probes rather than joins: each is
  # one lookup in a unique index per candidate row, and a join would multiply
  # the candidate set by whatever it matched.
  #
  # Composed one clause at a time rather than as one expression, so that adding
  # a reason is adding a function rather than lengthening a boolean nobody can
  # read.
  defp kept_by_nobody do
    [&no_favourite/0, &no_bookmark/0, &no_pin/0, &no_local_mention/0, &no_local_reference/0]
    |> Enum.map(& &1.())
    |> Enum.reduce(fn clause, acc -> dynamic([s], ^acc and ^clause) end)
  end

  defp no_favourite do
    dynamic(
      [s],
      not exists(from(f in Favourite, where: f.status_id == parent_as(:vacuum).id, select: 1))
    )
  end

  defp no_bookmark do
    dynamic(
      [s],
      not exists(from(b in Bookmark, where: b.status_id == parent_as(:vacuum).id, select: 1))
    )
  end

  defp no_pin do
    dynamic(
      [s],
      not exists(from(p in Pin, where: p.status_id == parent_as(:vacuum).id, select: 1))
    )
  end

  # A mention of somebody on another server is no reason to keep anything: the
  # notification it would break is not one of ours.
  defp no_local_mention do
    dynamic(
      [s],
      not exists(
        from(m in Mention,
          join: a in Account,
          on: a.id == m.account_id,
          where: m.status_id == parent_as(:vacuum).id and is_nil(a.domain),
          select: 1
        )
      )
    )
  end

  # A boost, a reply or a quote written here. Checked as local rather than as
  # anybody's, because a remote reply to a remote post is as disposable as the
  # post itself and keeping either would keep whole foreign threads for ever.
  defp no_local_reference do
    dynamic(
      [s],
      not exists(
        from(r in Status,
          where:
            (r.reblog_of_id == parent_as(:vacuum).id or
               r.in_reply_to_id == parent_as(:vacuum).id) and r.local,
          select: 1
        )
      ) and
        not exists(
          from(q in "quotes",
            join: r in Status,
            on: r.id == q.status_id,
            where: q.quoted_status_id == parent_as(:vacuum).id and r.local,
            select: 1
          )
        )
    )
  end
end
