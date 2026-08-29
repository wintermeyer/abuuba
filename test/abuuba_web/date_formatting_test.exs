defmodule AbuubaWeb.DateFormattingTest do
  @moduledoc """
  Every date a person reads goes through `AbuubaWeb.Formats`.

  This is an enumeration rather than a habit on purpose. The rule is easy to
  state and easy to forget, and forgetting it is invisible: a hand-rolled
  `%Y-%m-%d` renders perfectly, passes every test written against the page it
  is on, and is only wrong to a reader who expects `5.12.2026`. `Formats` had
  its own passing test suite and no production caller at all while twenty call
  sites formatted dates by hand, so a test of the formatter proves nothing
  about whether anybody uses it.

  ## What this cannot catch

  One spelling, `Calendar.strftime`. It is the mechanical one and it was all
  twenty of the original offenders, but it is not the only way to put an
  unformatted date on a page: `document_live.ex` reached the same end through
  `to_string/1` on a `%Date{}` and through interpolating one straight into a
  gettext binding, and this test was blind to both. They were found by reading,
  not by running this.

  So the set is not closed, and it cannot be closed textually, because the
  legitimate uses look identical to the illegitimate ones: `DateTime.to_iso8601`
  in a `<time datetime=...>` attribute and a `%Date{}` in a URL path are both
  right, and both are machine formats that must stay ISO. Treat a green run
  here as "the known spelling is absent", not "every date is formatted".

  ## Why it stops at the web layer

  `lib/abuuba` formats dates for machines that have their own spelling and would
  break if it changed: an AWS SigV4 stamp in `media/storage/s3.ex` and the
  RFC 7231 `Date` header in `federation/signature.ex`, which is English and GMT
  by specification. Widening this to `lib/` would fail on all three and the
  only way to pass would be to make them wrong.
  """

  use ExUnit.Case, async: true

  alias AbuubaWeb.Formats
  alias AbuubaWeb.Plugs.Locale

  @web_root "lib/abuuba_web"

  setup do
    on_exit(fn -> Locale.put_locale("en") end)
    :ok
  end

  test "nothing in the web layer formats a date by hand" do
    offenders =
      @web_root
      |> Path.join("**/*.{ex,heex}")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> String.contains?(line, "Calendar.strftime") end)
        |> Enum.map(fn {_line, n} -> "#{path}:#{n}" end)
      end)

    assert offenders == [],
           """
           These format a date without going through AbuubaWeb.Formats:

           #{Enum.join(offenders, "\n")}

           Use Formats.date/2 or Formats.datetime/2 so the reader's locale
           decides the order and the separators.
           """
  end

  test "a German reader does not get an ISO date" do
    Locale.put_locale("de")

    assert Formats.date(~D[2026-12-05]) =~ "5"
    refute Formats.date(~D[2026-12-05]) =~ "2026-12-05"
  end

  # The audit log and the report notes are read through schemaless queries,
  # which hand a timestamp back without a zone. Half the admin area's dates
  # arrive this way, so a formatter that only took DateTime crashed those
  # pages the moment they were routed through it.
  test "a timestamp without a zone formats as the UTC it is" do
    naive = ~N[2026-12-05 14:30:00]

    Locale.put_locale("de")
    assert Formats.datetime(naive) == Formats.datetime(~U[2026-12-05 14:30:00Z])
    assert Formats.date(naive) == Formats.date(~D[2026-12-05])
  end

  # The instance counts on /about are the ones that get big, and they are on a
  # public page. A run-together 60023 is the bug; 60.023 against 60,023 is the
  # point, and the two invert between locales, so an unformatted number is
  # misread rather than merely untidy.
  test "a large count is grouped for the reader" do
    Locale.put_locale("de")
    assert Formats.number(60_023) == "60.023"

    Locale.put_locale("en")
    assert Formats.number(60_023) == "60,023"
  end

  # Routing a number through a formatter must not turn a missing value into a
  # 500. The hashtag counts on an annual report come out of a JSON column, so
  # the key can be absent; before the sweep that rendered as nothing, and Cldr
  # raises on it rather than answering an error tuple.
  test "a missing number renders as nothing rather than raising" do
    assert Formats.number(nil) == ""
  end

  # Minutes, and a year somebody can cite. Neither of CLDR's own pairings
  # gives both.
  test "a datetime carries the full year and no seconds" do
    at = ~U[2026-12-05 14:30:45Z]

    Locale.put_locale("de")
    assert Formats.datetime(at) == "05.12.2026, 14:30"

    Locale.put_locale("en")
    refute Formats.datetime(at) =~ "45"
    assert Formats.datetime(at) =~ "2026"
  end
end
