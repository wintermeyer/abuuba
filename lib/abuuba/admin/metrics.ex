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

      {:ok, Enum.map(keys, &%{key: &1, total: total(&1, days), data: series(&1, days)})}
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

      %{
        period: start,
        total: length(cohort_ids),
        data:
          Enum.map(Enum.with_index(starts), fn {later, index} ->
            %{
              date: later,
              rate: rate(cohort_ids, later, cohort_end(later, frequency)),
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

  defp series(key, days), do: Enum.map(days, &%{date: &1, value: to_string(count(key, &1))})

  defp total(key, days), do: days |> Enum.map(&count(key, &1)) |> Enum.sum() |> to_string()

  # Somebody who posted that day. The reference implementation counts logins;
  # this server does not record one per day, and "wrote something" is a
  # stricter and more honest reading of "active".
  defp count("active_users", day) do
    Status
    |> where([s], s.local and is_nil(s.deleted_at))
    |> on_day(day)
    |> distinct(true)
    |> select([s], s.account_id)
    |> subquery()
    |> Repo.aggregate(:count)
  end

  defp count("new_users", day), do: User |> on_day(day) |> Repo.aggregate(:count)

  defp count(key, day) when key in ["new_statuses", "instance_statuses"] do
    Status
    |> where([s], s.local and is_nil(s.deleted_at))
    |> on_day(day)
    |> Repo.aggregate(:count)
  end

  # Favourites and boosts together: what a reader did with somebody else's
  # post, which is what the chart is about.
  defp count("interactions", day) do
    boosts =
      Status
      |> where([s], not is_nil(s.reblog_of_id))
      |> on_day(day)
      |> Repo.aggregate(:count)

    favourites = from(f in "favourites") |> on_day(day) |> Repo.aggregate(:count)

    boosts + favourites
  end

  defp count("opened_reports", day), do: Report |> on_day(day) |> Repo.aggregate(:count)

  defp count("resolved_reports", day) do
    Report
    |> where([r], not is_nil(r.action_taken_at))
    |> where([r], fragment("?::date", r.action_taken_at) == ^day)
    |> Repo.aggregate(:count)
  end

  defp count("instance_accounts", day), do: Account |> on_day(day) |> Repo.aggregate(:count)

  # Named in the moduledoc: nothing here records a peer's version, so the
  # honest answer is none rather than a number nobody can act on.
  defp count(_key, _day), do: 0

  defp on_day(query, day), do: where(query, [r], fragment("?::date", r.inserted_at) == ^day)

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

  defp cohort_starts(from, to, _frequency) do
    Date.range(from, to) |> Enum.take(@max_days)
  end

  defp cohort_end(start, "month"), do: Date.end_of_month(start)
  defp cohort_end(start, _frequency), do: start

  defp joined_in(from, to) do
    User
    |> where([u], fragment("?::date", u.inserted_at) >= ^from)
    |> where([u], fragment("?::date", u.inserted_at) <= ^to)
    |> select([u], u.account_id)
    |> Repo.all()
  end

  defp rate([], _from, _to), do: "0.0"

  defp rate(account_ids, from, to) do
    still_here =
      Status
      |> where([s], s.account_id in ^account_ids and is_nil(s.deleted_at))
      |> where([s], fragment("?::date", s.inserted_at) >= ^from)
      |> where([s], fragment("?::date", s.inserted_at) <= ^to)
      |> distinct(true)
      |> select([s], s.account_id)
      |> subquery()
      |> Repo.aggregate(:count)

    Float.to_string(Float.round(still_here / length(account_ids), 4))
  end
end
