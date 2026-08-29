defmodule Abuuba.Bench.Dataset do
  @moduledoc """
  The data both servers are given, described once.

  A comparison is only worth reading if both sides were asked the same
  question. That means the same accounts, the same follow graph and the same
  posts — not "about ten thousand followers each", which is how one side ends
  up with a fan-out ten per cent cheaper than the other for reasons nobody
  wrote down.

  So the dataset is generated from a fixed seed and described here, in a form
  both seeders read: abuuba's is an Elixir script, Mastodon's is a Rails runner
  script, and both produce exactly these handles in exactly this order.

  ## Sizes

  A size is a follower count. `bench/run.sh 5000` is a run with five thousand
  followers, and no name has to be invented for it first — which matters
  because the interesting sizes are whatever somebody wants to see the curve
  through, not four words picked in advance.

  Four names survive as shorthand, because earlier results were recorded under
  them: `:small` is a thousand, `:medium` ten thousand, `:large` a hundred
  thousand, `:huge` a million.

  ## Why the bigger sizes carry fewer posts

  Both servers write a feed row per follower per post, so the seeded work is
  `followers × statuses` and it is the *product* that decides how long a run
  takes, not either number on its own. Holding 200 posts at a million followers
  means two hundred million rows: roughly three hours of seeding on the abuuba
  side, and on the other some ten days.

  That last figure rests on Mastodon's drain rate, which is worth stating
  carefully because every size estimate anyone makes here rests on it too. Two
  measurements exist. The August 2026 report recorded about 220 jobs a second.
  A live sample during a 2026-08-28 run, two counter readings 121 seconds
  apart, gave 179.6. Neither is wrong: the rate falls as the feed table grows,
  because index maintenance costs more with every row, so a figure taken
  against 200,000 rows will overstate what happens against two million. Use the
  lower one for planning and expect it to sag further at the large sizes.

  So anything past a thousand followers carries 20 posts rather than 200:

      1k     × 200 =    200,000 rows
      5k     ×  20 =    100,000 rows
      50k    ×  20 =  1,000,000 rows
      100k   ×  20 =  2,000,000 rows
      1M     ×  20 = 20,000,000 rows

  That also makes every size above a thousand directly comparable with every
  other, which is what a scaling curve needs; the thousand-follower size is the
  odd one out and its numbers should not be read as a point on that curve. A
  run is only comparable with another run of the same size, so the report
  prints the size and the seed.

  ## Names are boring on purpose

  `bench0001`, and so on. A generated handle that looked like a person's would
  be a person's the first time somebody points this at a server that is not
  empty.
  """

  @named %{
    small: 1_000,
    medium: 10_000,
    large: 100_000,
    huge: 1_000_000
  }

  # Above this many followers a run carries fewer posts. See the note above on
  # why the product is what matters.
  @many_followers 1_000
  @posts_for_small 200
  @posts_for_large 20

  # Fixed, because the point is that two runs on two servers are the same run.
  @seed 20_260_806

  @doc """
  The names a run can be asked for.

  A size does not have to be one of these: any follower count works, so
  `bench/run.sh 5000` needs no name to be invented for it first. The names are
  kept because they are what earlier results were recorded under.
  """
  @spec profiles() :: [atom()]
  def profiles, do: @named |> Map.keys() |> Enum.sort()

  @doc """
  What one size means, from a name or from a plain follower count.

  Returns `nil` for anything that is neither, so a typo fails at the argument
  rather than by seeding an empty instance and measuring it.
  """
  @spec profile(atom() | integer() | String.t()) :: map() | nil
  def profile(count) when is_integer(count) and count > 0 do
    statuses = if count > @many_followers, do: @posts_for_large, else: @posts_for_small

    %{followers: count, statuses: statuses, label: "#{label_count(count)} followers"}
  end

  def profile(name) when is_atom(name) do
    case Map.fetch(@named, name) do
      {:ok, count} -> profile(count)
      :error -> nil
    end
  end

  def profile(name) when is_binary(name) do
    case Integer.parse(name) do
      {count, ""} -> profile(count)
      _not_a_number -> named_profile(name)
    end
  end

  def profile(_unknown), do: nil

  defp named_profile(name) do
    case Enum.find(Map.keys(@named), &(Atom.to_string(&1) == name)) do
      nil -> nil
      found -> profile(found)
    end
  end

  # `1M` rather than `1000000`, and `5k` rather than `5000`, because the label
  # goes in a report heading.
  defp label_count(count) when rem(count, 1_000_000) == 0, do: "#{div(count, 1_000_000)}M"
  defp label_count(count) when rem(count, 1_000) == 0, do: "#{div(count, 1_000)}k"
  defp label_count(count), do: to_string(count)

  @doc """
  The account everything is measured against: the one that posts, and whose
  home timeline is read.
  """
  @spec subject() :: String.t()
  def subject, do: "benchsubject"

  @doc """
  The follower handles for a size, in order.

  A list rather than a stream, because both seeders write them in one go and
  the largest of them is a hundred thousand short strings.
  """
  @spec followers(atom() | integer() | String.t()) :: [String.t()]
  def followers(name) do
    case profile(name) do
      nil -> []
      %{followers: count} -> Enum.map(1..count, &handle/1)
    end
  end

  @doc """
  One follower's handle, by position.
  """
  @spec handle(pos_integer()) :: String.t()
  def handle(index), do: "bench" <> String.pad_leading(to_string(index), 6, "0")

  @doc """
  The posts the subject account is seeded with, oldest first.

  Deterministic text: a benchmark that measured a different number of bytes on
  each side would be measuring the text rather than the server.
  """
  @spec statuses(atom() | integer() | String.t()) :: [String.t()]
  def statuses(name) do
    case profile(name) do
      nil -> []
      %{statuses: count} -> Enum.map(1..count, &text/1)
    end
  end

  @doc """
  One post's text, by position.
  """
  @spec text(pos_integer()) :: String.t()
  def text(index) do
    "Benchmark post #{index}. " <>
      String.duplicate("The quick brown fox jumps over the lazy dog. ", 3)
  end

  @doc """
  The seed both sides use, so a reader can check they were given the same data.
  """
  @spec seed() :: pos_integer()
  def seed, do: @seed

  @doc """
  A one-line description of the dataset, for the report.
  """
  @spec describe(atom() | integer() | String.t()) :: String.t()
  def describe(name) do
    case profile(name) do
      nil ->
        "unknown size"

      %{followers: followers, statuses: statuses, label: label} ->
        "#{label}: 1 subject account, #{followers} followers, #{statuses} existing posts (seed #{@seed})"
    end
  end
end
