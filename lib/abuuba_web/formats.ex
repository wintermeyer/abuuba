defmodule AbuubaWeb.Formats do
  @moduledoc """
  Dates, times and numbers in the reader's language.

  Gettext handles the words. This handles everything around them, which is the
  half that quietly gives software away as foreign: a German reader expects
  5.12.2026 and 1.234,5 where an English one expects 12/5/2026 and 1,234.5.

  Every function here takes the locale from the current process, which the
  locale plug and the LiveView hook both set, so callers do not have to thread
  it through.
  """

  use Gettext, backend: AbuubaWeb.Gettext

  alias Abuuba.Cldr

  @doc """
  A date in the reader's conventions.
  """
  @spec date(DateTime.t() | NaiveDateTime.t() | Date.t(), keyword()) :: String.t()
  def date(value, opts \\ []) do
    case Cldr.Date.to_string(to_date(value), Keyword.put_new(opts, :format, :medium)) do
      {:ok, formatted} -> formatted
      {:error, _reason} -> fallback(value)
    end
  end

  @doc """
  A date and time in the reader's conventions.

  A full year and minutes, no seconds: `05.12.2026, 14:30` against
  `Dec 5, 2026, 2:30 PM`. That is neither of CLDR's own pairings, and it is
  what every caller here wants. `:medium` on both halves spends a line on
  seconds nobody reads off a log; `:short` on both drops the century, which
  reads badly on an audit entry somebody is citing. Pass `format:` to override
  the pair.
  """
  @spec datetime(DateTime.t() | NaiveDateTime.t(), keyword()) :: String.t()
  def datetime(value, opts \\ [])

  # Ecto hands a timestamp back without a zone when it is read through a
  # schemaless query, which is how the audit log and the report notes arrive.
  # Every one of them is stored UTC, so saying so here beats making each
  # caller convert and beats a formatter that crashes on half the app's
  # timestamps.
  def datetime(%NaiveDateTime{} = value, opts) do
    value |> DateTime.from_naive!("Etc/UTC") |> datetime(opts)
  end

  def datetime(%DateTime{} = value, opts) do
    opts =
      if Keyword.has_key?(opts, :format) do
        opts
      else
        opts
        |> Keyword.put_new(:date_format, :medium)
        |> Keyword.put_new(:time_format, :short)
      end

    {label?, opts} = Keyword.pop(opts, :zone, false)

    case Cldr.DateTime.to_string(value, opts) do
      {:ok, formatted} -> with_zone(formatted, label?)
      {:error, _reason} -> with_zone(fallback(value), label?)
    end
  end

  # One string with a placeholder rather than a formatted time with the word
  # stuck on the end: where the zone goes in a sentence is the translation's
  # business, and some languages do not put it last.
  defp with_zone(formatted, false), do: formatted
  defp with_zone(formatted, true), do: gettext("%{time} UTC", time: formatted)

  @doc """
  The same instant, written so a machine cannot misread it.

  This is what goes in a `datetime` attribute. `Z` on the end rather than a
  bare local-looking string: every timestamp in this database is UTC, and a
  browser parsing one without a zone is a browser guessing.
  """
  @spec iso(DateTime.t() | NaiveDateTime.t()) :: String.t()
  def iso(%NaiveDateTime{} = value), do: value |> DateTime.from_naive!("Etc/UTC") |> iso()

  def iso(%DateTime{} = value) do
    value |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  @doc """
  A number in the reader's conventions, grouped and with the right decimal
  separator.
  """
  @spec number(number() | nil, keyword()) :: String.t()
  def number(value, opts \\ []) do
    # Cldr raises on something that is not a number rather than answering an
    # error tuple, and the counts here come out of JSON columns where a key
    # can simply be absent. A missing count used to render as nothing at all,
    # which is the right amount of noise; it should not become a 500 because
    # the number now goes through a formatter.
    case Cldr.Number.to_string(value, opts) do
      {:ok, formatted} -> formatted
      {:error, _reason} -> to_string(value)
    end
  rescue
    _ in [ArgumentError, FunctionClauseError] -> to_string(value)
  end

  @doc """
  How long ago something happened, as a timeline shows it: "3 minutes ago",
  "vor 3 Minuten".

  Timelines are read in the present tense, so an absolute timestamp makes the
  reader do arithmetic to answer the only question they actually have. Past a
  week the arithmetic stops being trivial and this returns a date instead.
  """
  @spec relative_time(DateTime.t(), DateTime.t()) :: String.t()
  def relative_time(%DateTime{} = value, now \\ DateTime.utc_now()) do
    seconds = DateTime.diff(now, value, :second)

    cond do
      seconds < 0 -> date(value)
      seconds < 60 -> gettext("just now")
      seconds < 3600 -> ngettext("1 minute ago", "%{count} minutes ago", div(seconds, 60))
      seconds < 86_400 -> ngettext("1 hour ago", "%{count} hours ago", div(seconds, 3600))
      seconds < 604_800 -> ngettext("1 day ago", "%{count} days ago", div(seconds, 86_400))
      true -> date(value)
    end
  end

  defp to_date(%DateTime{} = value), do: DateTime.to_date(value)
  defp to_date(%NaiveDateTime{} = value), do: NaiveDateTime.to_date(value)
  defp to_date(%Date{} = value), do: value

  # A formatter that cannot render is not worth a 500. ISO 8601 is wrong for
  # the reader but readable, and the page still comes back.
  defp fallback(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp fallback(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp fallback(%Date{} = value), do: Date.to_iso8601(value)
end
