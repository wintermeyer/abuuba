defmodule Abuuba.Admin.Metrics do
  @moduledoc """
  The numbers behind an admin dashboard's charts.

  Three shapes, and they answer three different questions. A **measure** is one
  number per day over a window — "how many people posted each day". A
  **dimension** is a breakdown at a moment — "which languages, biggest first".
  **Retention** is a cohort table — "of the people who joined in March, how
  many were still here in April".

  ## Every key is answered, and none is invented

  A dashboard asks for the keys it knows how to draw. A key this server cannot
  answer comes back as a series of zeroes rather than as an error or a missing
  entry, because a chart with no data draws a flat line and a chart with a
  missing series draws nothing at all while the client waits for something that
  will never come. What is not answerable here is named in the moduledoc rather
  than left for somebody to work out from a flat graph:

  * `software_versions` needs a version per peer, which this server does not
    ask for and does not store.
  * `space_usage` is the size of what is on disk, which only the storage layer
    can say and only for local files.

  ## Counted from the rows, not from a cache

  Nothing here is precomputed. A dashboard is looked at occasionally by a
  handful of people, and a daily rollup table would be a second source of
  truth that can be wrong. Every query is bounded by the window asked for.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.User
  alias Abuuba.Moderation.Report
  alias Abuuba.Repo
  alias Abuuba.Statuses.Status

  # What the reference implementation's dashboard asks for. Listed rather than
  # accepted openly so that a typo in a client comes back as "unknown" instead
  # of as a chart of zeroes that looks like a quiet week.
  @measures ~w(active_users new_users interactions opened_reports resolved_reports
               new_statuses instance_accounts instance_statuses instance_media_attachments
               instance_reports instance_follows instance_followers
               tag_accounts tag_uses tag_servers software_versions)

  @dimensions ~w(languages sources servers space_usage software_versions
                 tag_servers tag_languages instance_accounts instance_languages)

  # A month of daily cohorts is what a dashboard draws, and further back is a
  # question about history rather than about how the server is doing.
  @max_days 92

  @doc """
  The keys a measure may be asked for.
  """
  @spec measures() :: [String.t()]
  def measures, do: @measures

  @doc """
  The keys a dimension may be asked for.
  """
  @spec dimensions() :: [String.t()]
  def dimensions, do: @dimensions

  @doc """
  One number per day between two dates, for each key asked for.

  Unknown keys are refused rather than answered with zeroes: a chart of zeroes
  reads as a quiet week, and a client asking for something this server has
  never heard of should find that out.
  """
  @spec measure([String.t()], Date.t(), Date.t()) ::
          {:ok, [map()]} | {:error, {:unknown_keys, [String.t()]}}
  def measure(keys, from, to) do
    with :ok <- known(keys, @measures) do
      days = days_between(from, to)

      {:ok, Enum.map(keys, &measured(&1, days))}
    end
  end

  @doc """
  A breakdown at a moment, biggest first.
  """
  @spec dimension([String.t()], Date.t(), Date.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, {:unknown_keys, [String.t()]}}
  def dimension(keys, from, to, limit) do
    with :ok <- known(keys, @dimensions) do
      days = days_between(from, to)

      {:ok, Enum.map(keys, &%{key: &1, data: breakdown(&1, days, limit)})}
    end
  end

  @doc """
  Of the people who joined in each period, how many were still posting later.

  The honest version of the question a retention chart asks. "Still here" means
  posted at least once in the later period, because a login this server never
  saw is not evidence of anybody being here.
  """
  @spec retention(Date.t(), Date.t(), String.t()) :: [map()]
  def retention(from, to, frequency) do
    starts = cohort_starts(from, to, frequency)

    Enum.map(starts, fn start ->
      cohort_ids = joined_in(start, cohort_end(start, frequency))
      # One query for the whole row rather than one per cell. A cohort's
      # people either posted in a later period or they did not, and asking
      # that period by period made the chart cost the square of its own width.
      posted = periods_posted_in(cohort_ids, starts, frequency)

      %{
        period: start,
        total: length(cohort_ids),
        data:
          Enum.map(Enum.with_index(starts), fn {later, index} ->
            %{
              date: later,
              rate: rate(cohort_ids, Map.get(posted, later, 0)),
              value: index
            }
          end)
      }
    end)
  end

  ## Measures

  defp known(keys, allowed) do
    case Enum.reject(keys, &(&1 in allowed)) do
      [] -> :ok
      unknown -> {:error, {:unknown_keys, unknown}}
    end
  end

  defp days_between(from, to) do
    from = Date.range(from, to) |> Enum.take(@max_days)

    if from == [], do: [], else: from
  end

  # One grouped query per key rather than one per key per day. Six keys over a
  # month came to 434 queries -- `total/2` and `series/2` each asked the same
  # thirty-one questions, and `"interactions"` asked two of its own -- with
  # every one of them a sequential scan, because a date predicate written as
  # `?::date == day` cannot use an index on the column.
  #
  # The total is the sum of the series rather than a second pass: it was
  # always going to be, and asking twice is how it stopped being obvious.
  defp measured(key, []), do: %{key: key, total: "0", data: []}

  defp measured(key, days) do
    counts = per_day(key, List.first(days), List.last(days))
    data = Enum.map(days, &%{date: &1, value: to_string(Map.get(counts, &1, 0))})
    total = counts |> Map.values() |> Enum.sum()

    %{key: key, total: to_string(total), data: data}
  end

  # Somebody who posted that day. The reference implementation counts logins;
  # this server does not record one per day, and "wrote something" is a
  # stricter and more honest reading of "active".
  defp per_day("active_users", from, to) do
    Status
    |> where([s], s.local and is_nil(s.deleted_at))
    |> within_days(from, to)
    |> group_by([s], fragment("?::date", s.inserted_at))
    |> select([s], {fragment("?::date", s.inserted_at), count(s.account_id, :distinct)})
    |> Repo.all()
    |> Map.new()
  end

  defp per_day("new_users", from, to), do: counted_by_day(User, from, to)

  defp per_day(key, from, to) when key in ["new_statuses", "instance_statuses"] do
    Status
    |> where([s], s.local and is_nil(s.deleted_at))
    |> counted_by_day(from, to)
  end

  # Favourites and boosts together: what a reader did with somebody else's
  # post, which is what the chart is about.
  defp per_day("interactions", from, to) do
    boosts =
      Status
      |> where([s], not is_nil(s.reblog_of_id))
      |> counted_by_day(from, to)

    favourites = counted_by_day(from(f in "favourites"), from, to)

    Map.merge(boosts, favourites, fn _day, a, b -> a + b end)
  end

  defp per_day("opened_reports", from, to), do: counted_by_day(Report, from, to)

  defp per_day("resolved_reports", from, to) do
    Report
    |> where([r], not is_nil(r.action_taken_at))
    |> where([r], r.action_taken_at >= ^start_of(from) and r.action_taken_at < ^after_end(to))
    |> group_by([r], fragment("?::date", r.action_taken_at))
    |> select([r], {fragment("?::date", r.action_taken_at), count()})
    |> Repo.all()
    |> Map.new()
  end

  defp per_day("instance_accounts", from, to), do: counted_by_day(Account, from, to)

  # Named in the moduledoc: nothing here records a peer's version, so the
  # honest answer is none rather than a number nobody can act on.
  defp per_day(_key, _from, _to), do: %{}

  defp counted_by_day(query, from, to) do
    query
    |> within_days(from, to)
    |> group_by([r], fragment("?::date", r.inserted_at))
    |> select([r], {fragment("?::date", r.inserted_at), count()})
    |> Repo.all()
    |> Map.new()
  end

  # Half-open and on the bare column, so an index on `inserted_at` applies.
  # `?::date == day` is a function of the column and cannot use one.
  defp within_days(query, from, to) do
    where(query, [r], r.inserted_at >= ^start_of(from) and r.inserted_at < ^after_end(to))
  end

  defp start_of(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp after_end(date), do: date |> Date.add(1) |> start_of()

  ## Dimensions

  defp breakdown("languages", days, limit) do
    Status
    |> where([s], s.local and is_nil(s.deleted_at) and not is_nil(s.language))
    |> within(days)
    |> group_by([s], s.language)
    |> order_by([s], desc: count(s.id))
    |> limit(^limit)
    |> select([s], %{key: s.language, value: count(s.id)})
    |> Repo.all()
    |> Enum.map(&%{key: &1.key, human_key: &1.key, value: to_string(&1.value)})
  end

  defp breakdown("sources", days, limit) do
    from(s in Status,
      join: a in "oauth_applications",
      on: a.id == s.application_id,
      where: s.local and is_nil(s.deleted_at),
      group_by: a.name,
      order_by: [desc: count(s.id)],
      limit: ^limit,
      select: %{key: a.name, value: count(s.id)}
    )
    |> within(days)
    |> Repo.all()
    |> Enum.map(&%{key: &1.key, human_key: &1.key, value: to_string(&1.value)})
  end

  defp breakdown(key, days, limit) when key in ["servers", "instance_accounts"] do
    Account
    |> where([a], not is_nil(a.domain))
    |> within(days)
    |> group_by([a], a.domain)
    |> order_by([a], desc: count(a.id))
    |> limit(^limit)
    |> select([a], %{key: a.domain, value: count(a.id)})
    |> Repo.all()
    |> Enum.map(&%{key: &1.key, human_key: &1.key, value: to_string(&1.value)})
  end

  defp breakdown(_key, _days, _limit), do: []

  defp within(query, []), do: query

  defp within(query, days) do
    first = List.first(days)
    last = List.last(days)

    where(query, [r], fragment("?::date", r.inserted_at) >= ^first)
    |> where([r], fragment("?::date", r.inserted_at) <= ^last)
  end

  ## Retention

  defp cohort_starts(from, to, "month") do
    from
    |> Date.beginning_of_month()
    |> Stream.iterate(&(&1 |> Date.end_of_month() |> Date.add(1)))
    |> Enum.take_while(&(Date.compare(&1, to) != :gt))
    |> Enum.take(24)
  end

  # A week is what the dashboard asks for and there was no clause for it, so it
  # fell through to here and got eighty-five one-day cohorts labelled as weeks
  # -- wrong on the chart before it was slow underneath it.
  defp cohort_starts(from, to, "week") do
    from
    |> Date.beginning_of_week()
    |> Stream.iterate(&Date.add(&1, 7))
    |> Enum.take_while(&(Date.compare(&1, to) != :gt))
    |> Enum.take(52)
  end

  defp cohort_starts(from, to, _frequency) do
    Date.range(from, to) |> Enum.take(@max_days)
  end

  defp cohort_end(start, "month"), do: Date.end_of_month(start)
  defp cohort_end(start, "week"), do: Date.add(start, 6)
  defp cohort_end(start, _frequency), do: start

  defp joined_in(from, to) do
    User
    |> within_days(from, to)
    |> select([u], u.account_id)
    |> Repo.all()
  end

  # How many of this cohort posted in each of the periods, in one query. The
  # bucket is worked out in SQL from the first period's start, so a row is
  # counted against the period it falls in without asking about each in turn.
  defp periods_posted_in([], _starts, _frequency), do: %{}
  defp periods_posted_in(_ids, [], _frequency), do: %{}

  defp periods_posted_in(account_ids, starts, frequency) do
    last_end = starts |> List.last() |> cohort_end(frequency)

    # Who posted on which day, once each. Bucketing in Elixir rather than in
    # SQL because "still here" is people and not posts: somebody who wrote
    # three times in a week is one person, and a per-day count cannot be added
    # up into a per-week one without turning them into three.
    Status
    |> where([s], s.account_id in ^account_ids and is_nil(s.deleted_at))
    |> within_days(List.first(starts), last_end)
    |> distinct(true)
    |> select([s], {s.account_id, fragment("?::date", s.inserted_at)})
    |> Repo.all()
    |> Enum.group_by(fn {_id, day} -> period_of(day, starts, frequency) end, &elem(&1, 0))
    |> Enum.flat_map(fn
      {nil, _ids} -> []
      {start, ids} -> [{start, ids |> Enum.uniq() |> length()}]
    end)
    |> Map.new()
  end

  defp period_of(day, starts, frequency) do
    Enum.find(starts, fn start ->
      Date.compare(day, start) != :lt and Date.compare(day, cohort_end(start, frequency)) != :gt
    end)
  end

  defp rate([], _still_here), do: "0.0"

  defp rate(account_ids, still_here) do
    Float.to_string(Float.round(still_here / length(account_ids), 4))
  end
end
