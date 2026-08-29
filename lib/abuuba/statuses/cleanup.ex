defmodule Abuuba.Statuses.Cleanup do
  @moduledoc """
  Somebody's standing instruction to delete their own old posts.

  ## Off unless somebody turned it on

  Deleting posts on a schedule is not a thing to end up with by accident, so
  the column is null until somebody sets an age and there is no default age
  waiting to be applied.

  ## The exceptions are the feature

  A blanket "delete everything older than a year" is not what anybody wants;
  what they want is that most of it goes and a few things stay. So: pinned
  posts stay by default, posts with pictures can stay, and a post that enough
  people favourited or boosted can stay. Somebody using this is saying "the
  chatter goes, the things that mattered keep", and the thresholds are how they
  say which was which.

  ## Deleted the same way one delete is

  Through `Abuuba.Statuses.delete_status/1`, one at a time, so that peers are
  told, feeds are cleaned and counters unwind exactly as they do when somebody
  presses delete on a single post. A bulk `delete_all` here would be quicker
  and would leave every one of those jobs undone.

  ## A batch at a time

  An account with ten years of posts is not a transaction. Each run takes a
  bounded batch, oldest first, and the next run takes the next one; the sweep
  is hourly, so a large backlog drains over a day or two rather than blocking
  a job for an hour.
  """

  import Ecto.Query

  alias Abuuba.Accounts.User
  alias Abuuba.Repo
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Status

  @batch 100

  @doc """
  The users who have asked for this.
  """
  @spec subscribers(pos_integer()) :: [User.t()]
  def subscribers(limit \\ 100) do
    User
    |> where([u], not is_nil(u.cleanup_after_days))
    |> order_by([u], asc_nulls_first: u.cleanup_last_run_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Deletes one batch of one person's old posts, and returns how many went.
  """
  @spec run(User.t()) :: non_neg_integer()
  def run(%User{cleanup_after_days: nil}), do: 0

  def run(%User{} = user) do
    deleted =
      user
      |> due(@batch)
      |> Enum.map(&Statuses.delete_status/1)
      |> length()

    Repo.update_all(
      from(u in User, where: u.id == ^user.id),
      set: [cleanup_last_run_at: DateTime.utc_now()]
    )

    deleted
  end

  @doc """
  The posts one person's settings say may go, oldest first.

  Public so that the settings page can say how many there are before somebody
  turns this on. Being told "this will delete about four hundred posts" before
  the fact is the difference between a setting and a surprise.
  """
  @spec due(User.t(), pos_integer() | :count) :: [Status.t()] | non_neg_integer()
  def due(user, limit \\ @batch)

  def due(%User{cleanup_after_days: nil}, :count), do: 0
  def due(%User{cleanup_after_days: nil}, _limit), do: []

  def due(%User{} = user, :count), do: user |> due_query() |> Repo.aggregate(:count)

  def due(%User{} = user, limit) do
    user |> due_query() |> limit(^limit) |> Repo.all()
  end

  defp due_query(%User{} = user) do
    cutoff = DateTime.add(DateTime.utc_now(), -user.cleanup_after_days * 86_400, :second)

    Status
    |> where([s], s.account_id == ^user.account_id and is_nil(s.deleted_at))
    |> where([s], s.inserted_at < ^cutoff)
    |> keep_pinned(user)
    |> keep_media(user)
    |> keep_favourited(user)
    |> keep_boosted(user)
    |> order_by([s], asc: s.id)
  end

  # A pinned post is one somebody deliberately put at the top of their profile.
  # Deleting it on a schedule they set for the chatter would be the software
  # ignoring the more specific of two instructions.
  defp keep_pinned(query, %User{cleanup_keep_pinned: false}), do: query

  defp keep_pinned(query, %User{account_id: account_id}) do
    pinned = from p in "status_pins", where: p.account_id == ^account_id, select: p.status_id

    where(query, [s], s.id not in subquery(pinned))
  end

  defp keep_media(query, %User{cleanup_keep_media: false}), do: query

  defp keep_media(query, _user) do
    with_media =
      from m in "media_attachments", where: not is_nil(m.status_id), select: m.status_id

    where(query, [s], s.id not in subquery(with_media))
  end

  defp keep_favourited(query, %User{cleanup_min_favourites: nil}), do: query

  defp keep_favourited(query, %User{cleanup_min_favourites: threshold}) do
    from s in query,
      left_join: st in "status_stats",
      on: st.status_id == s.id,
      where: coalesce(st.favourites_count, 0) < ^threshold
  end

  defp keep_boosted(query, %User{cleanup_min_boosts: nil}), do: query

  defp keep_boosted(query, %User{cleanup_min_boosts: threshold}) do
    from s in query,
      left_join: st2 in "status_stats",
      on: st2.status_id == s.id,
      where: coalesce(st2.reblogs_count, 0) < ^threshold
  end
end
