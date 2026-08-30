defmodule Abuuba.AnnualReports do
  @moduledoc """
  A year in review, for the fortnight at the end of December when everybody
  wants one.

  ## Nothing in it is private

  The archetype, the counts, the busiest month, the most-used hashtag and the
  three posts that travelled furthest are all worked out from public and
  unlisted posts only. That is what makes the share page safe to be a page: a
  report that counted followers-only posts would publish how much somebody
  writes where nobody can see it, and the first person to notice would be the
  person it was about.

  ## Generated once, on request

  The queries walk a year of somebody's posts. Recomputing on every load would
  make this the most expensive screen on the server during exactly the fortnight
  everybody opens it, so a report is built once and kept, and building it twice
  is building it once.

  ## The campaign window is configuration, not the calendar

  Mastodon opens this between the 10th and the 31st of December. Reading the
  real clock would make the feature untestable except in December and would
  make the test suite fail on New Year's Eve, so the window is a config value
  the test environment sets. See `current_campaign/1`.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.AnnualReports.Report
  alias Abuuba.Notifications
  alias Abuuba.Relationships.Follow
  alias Abuuba.Repo
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.Tag

  @schema_version 1

  # The average a person posts in a year, which is what "did you post more or
  # less than everybody else" is measured against. The reference
  # implementation's number, so the archetypes mean the same thing.
  @average_per_year 113

  @doc """
  The year a report may be generated for right now, or `nil`.

  Configurable so that this is testable in July and does not break on the 1st
  of January. `config :abuuba, :annual_report_campaign, year` forces one; the
  default is the reference implementation's window.
  """
  @spec current_campaign(Date.t()) :: integer() | nil
  def current_campaign(today \\ Date.utc_today()) do
    case Application.get_env(:abuuba, :annual_report_campaign, :calendar) do
      :calendar -> if today.month == 12 and today.day >= 10, do: today.year
      :never -> nil
      year when is_integer(year) -> year
    end
  end

  @doc """
  The reports somebody has not looked at yet, newest year first.
  """
  @spec pending(Account.t() | integer()) :: [Report.t()]
  def pending(%Account{id: id}), do: pending(id)

  def pending(account_id) do
    Report
    |> where([r], r.account_id == ^account_id and is_nil(r.viewed_at))
    |> order_by([r], desc: r.year)
    |> Repo.all()
  end

  @doc """
  One of somebody's reports by id, or `nil`.
  """
  @spec get(Account.t() | integer(), term()) :: Report.t() | nil
  def get(%Account{id: id}, report_id), do: get(id, report_id)

  def get(account_id, report_id) do
    case Snowflake.cast(report_id) do
      {:ok, id} -> Repo.get_by(Report, id: id, account_id: account_id)
      :error -> nil
    end
  end

  @doc """
  One account's report for a year, whoever is asking.

  For the share page, which is public: see the module doc for why that is safe.
  """
  @spec for_year(Account.t() | integer(), term()) :: Report.t() | nil
  def for_year(%Account{id: id}, year), do: for_year(id, year)

  def for_year(account_id, year) do
    case year(year) do
      {:ok, year} -> Repo.get_by(Report, account_id: account_id, year: year)
      :error -> nil
    end
  end

  @doc """
  Where a report stands: `"available"`, `"eligible"` or `"ineligible"`.

  No `"generating"`: building one is a handful of counting queries rather than
  a job somebody waits on, so by the time a client could ask, it is done.
  """
  @spec state(Account.t(), integer()) :: String.t()
  def state(%Account{} = account, year) do
    cond do
      for_year(account, year) != nil -> "available"
      current_campaign() == year and eligible?(account, year) -> "eligible"
      true -> "ineligible"
    end
  end

  @doc """
  Whether there is enough of a year to be worth reporting on.

  One post is not a year in review. Somebody who joined in December gets
  nothing rather than a report saying they posted once, which reads as the
  server being sarcastic.
  """
  @spec eligible?(Account.t(), integer()) :: boolean()
  def eligible?(%Account{} = account, year) do
    account |> countable(year) |> Repo.aggregate(:count) > 1
  end

  @doc """
  Builds one, unless it exists already.
  """
  @spec generate(Account.t(), integer()) :: {:ok, Report.t()} | {:error, term()}
  def generate(%Account{} = account, year) do
    case for_year(account, year) do
      %Report{} = existing ->
        {:ok, existing}

      nil ->
        attrs = %{
          account_id: account.id,
          year: year,
          schema_version: @schema_version,
          data: build(account, year)
        }

        with {:ok, report} <- %Report{} |> Report.changeset(attrs) |> Repo.insert() do
          # Told, or nobody looks. The whole feature is somebody opening a
          # notification in the last fortnight of December.
          Notifications.notify(account, account.id, "annual_report")

          {:ok, report}
        end
    end
  end

  @doc """
  Records that its owner has seen it.
  """
  @spec mark_read(Report.t()) :: {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
  def mark_read(%Report{} = report) do
    report |> Report.changeset(%{viewed_at: DateTime.utc_now()}) |> Repo.update()
  end

  ## Building the thing

  defp build(account, year) do
    counts = counts(account, year)

    %{
      "archetype" => archetype(counts),
      "time_series" => time_series(account, year),
      "top_hashtags" => top_hashtags(account, year),
      "top_statuses" => top_statuses(account, year),
      "percentiles" => %{"statuses" => percentile(counts.total)}
    }
  end

  # Public and unlisted only, everywhere. See the module doc.
  defp countable(account, year) do
    Status
    |> where([s], s.account_id == ^account.id and is_nil(s.deleted_at))
    |> where([s], s.visibility in ^[:public, :unlisted])
    |> where([s], fragment("DATE_PART('year', ?) = ?", s.inserted_at, ^year))
  end

  defp counts(account, year) do
    base = countable(account, year)

    %{
      total: Repo.aggregate(base, :count),
      reblogs: base |> where([s], not is_nil(s.reblog_of_id)) |> Repo.aggregate(:count),
      replies:
        base
        |> where([s], not is_nil(s.in_reply_to_id))
        |> where([s], s.in_reply_to_account_id != ^account.id)
        |> Repo.aggregate(:count),
      standalone:
        base
        |> where([s], is_nil(s.reblog_of_id) and is_nil(s.in_reply_to_id))
        |> Repo.aggregate(:count),
      polls:
        base
        |> join(:inner, [s], p in "polls", on: p.status_id == s.id)
        |> Repo.aggregate(:count)
    }
  end

  # The reference implementation's ladder, in its order: the first one that
  # fits wins, and the order is what makes "mostly boosts" beat "mostly
  # replies" for somebody who does both.
  defp archetype(counts) do
    cond do
      counts.total < @average_per_year -> "lurker"
      counts.reblogs > counts.standalone * 2 -> "booster"
      counts.polls > counts.standalone * 0.1 -> "pollster"
      counts.replies > counts.standalone * 2 -> "replier"
      true -> "oracle"
    end
  end

  defp time_series(account, year) do
    posts =
      account
      |> countable(year)
      |> group_by([s], fragment("DATE_PART('month', ?)", s.inserted_at))
      |> select([s], {fragment("DATE_PART('month', ?)", s.inserted_at), count(s.id)})
      |> Repo.all()
      |> Map.new(fn {month, count} -> {trunc(month), count} end)

    followers =
      Follow
      |> where([f], f.target_account_id == ^account.id)
      |> where([f], fragment("DATE_PART('year', ?) = ?", f.inserted_at, ^year))
      |> group_by([f], fragment("DATE_PART('month', ?)", f.inserted_at))
      |> select([f], {fragment("DATE_PART('month', ?)", f.inserted_at), count(f.id)})
      |> Repo.all()
      |> Map.new(fn {month, count} -> {trunc(month), count} end)

    Enum.map(1..12, fn month ->
      %{
        "month" => month,
        "statuses" => Map.get(posts, month, 0),
        "followers" => Map.get(followers, month, 0)
      }
    end)
  end

  defp top_hashtags(account, year) do
    ids = account |> countable(year) |> select([s], s.id)

    from(t in Tag,
      join: st in "statuses_tags",
      on: st.tag_id == t.id,
      where: st.status_id in subquery(ids),
      group_by: t.name,
      order_by: [desc: count(st.status_id)],
      limit: 3,
      select: %{"name" => t.name, "count" => count(st.status_id)}
    )
    |> Repo.all()
  end

  # What travelled furthest, by what other people did with it rather than by
  # what its author thought of it.
  # Left-joined rather than read off the counter table, because a post nobody
  # touched has no counter row at all: joining the other way round would leave
  # a quiet year with no "biggest posts" section, which is exactly the year
  # somebody most wants three posts picked out of.
  defp top_statuses(account, year) do
    account
    |> countable(year)
    |> where([s], is_nil(s.reblog_of_id))
    |> join(:left, [s], st in "status_stats", on: st.status_id == s.id)
    |> order_by([s, st],
      desc: fragment("COALESCE(?, 0) + COALESCE(?, 0)", st.reblogs_count, st.favourites_count),
      desc: s.id
    )
    |> limit(3)
    |> select([s, st], %{
      "id" => s.id,
      "reblogs" => coalesce(st.reblogs_count, 0),
      "favourites" => coalesce(st.favourites_count, 0)
    })
    |> Repo.all()
    |> Enum.map(&%{&1 | "id" => Integer.to_string(&1["id"])})
  end

  # Rounded hard on purpose. "You posted more than most people" is the claim
  # this can honestly support; a number to two decimal places would be a
  # precision the sample does not have.
  defp percentile(total) do
    cond do
      total >= @average_per_year * 4 -> 99
      total >= @average_per_year * 2 -> 90
      total >= @average_per_year -> 75
      total >= div(@average_per_year, 4) -> 50
      true -> 25
    end
  end

  # A year, or nothing. `annual_reports.year` is a Postgres `integer`, so a
  # number outside int4 cannot name a row — and handing it to the query anyway
  # is not a lookup that finds nothing, it is Postgrex refusing to encode the
  # parameter, which surfaced as a 500 on a page anybody could reach.
  #
  # Separate from `numeric/1` on purpose: that one also reads report ids, which
  # are snowflakes and are supposed to be far larger than this.
  @int4 -2_147_483_648..2_147_483_647

  defp year(value) do
    case Snowflake.cast(value) do
      {:ok, year} when year in @int4 -> {:ok, year}
      _outside -> :error
    end
  end
end
