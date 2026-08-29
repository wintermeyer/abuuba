defmodule AbuubaWeb.FormatsTest do
  use ExUnit.Case, async: true

  alias AbuubaWeb.Formats
  alias AbuubaWeb.Plugs.Locale

  setup do
    on_exit(fn -> Locale.put_locale("en") end)
    :ok
  end

  describe "numbers and dates follow the reader, not the server" do
    test "a number is grouped and pointed the local way" do
      Locale.put_locale("en")
      assert Formats.number(1234.5) == "1,234.5"

      Locale.put_locale("de")
      assert Formats.number(1234.5) == "1.234,5"
    end

    test "a date is ordered the local way" do
      date = ~D[2026-12-05]

      Locale.put_locale("en")
      english = Formats.date(date)

      Locale.put_locale("de")
      german = Formats.date(date)

      refute english == german, "an English and a German date should not read alike"
      assert german =~ "2026"
      assert english =~ "2026"
    end

    test "a datetime renders in both" do
      at = ~U[2026-12-05 14:30:00Z]

      Locale.put_locale("en")
      assert is_binary(Formats.datetime(at))

      Locale.put_locale("de")
      assert is_binary(Formats.datetime(at))
    end
  end

  describe "relative_time/2" do
    setup do
      %{now: ~U[2026-08-05 12:00:00Z]}
    end

    test "reads in the present tense near the present", %{now: now} do
      Locale.put_locale("en")

      assert Formats.relative_time(DateTime.add(now, -5, :second), now) == "just now"
      assert Formats.relative_time(DateTime.add(now, -60, :second), now) == "1 minute ago"
      assert Formats.relative_time(DateTime.add(now, -300, :second), now) == "5 minutes ago"
      assert Formats.relative_time(DateTime.add(now, -3600, :second), now) == "1 hour ago"
      assert Formats.relative_time(DateTime.add(now, -7200, :second), now) == "2 hours ago"
      assert Formats.relative_time(DateTime.add(now, -86_400, :second), now) == "1 day ago"
      assert Formats.relative_time(DateTime.add(now, -172_800, :second), now) == "2 days ago"
    end

    test "is translated, including its plurals", %{now: now} do
      Locale.put_locale("de")

      assert Formats.relative_time(DateTime.add(now, -5, :second), now) == "gerade eben"
      assert Formats.relative_time(DateTime.add(now, -60, :second), now) == "vor 1 Minute"
      assert Formats.relative_time(DateTime.add(now, -300, :second), now) == "vor 5 Minuten"
      assert Formats.relative_time(DateTime.add(now, -7200, :second), now) == "vor 2 Stunden"
      assert Formats.relative_time(DateTime.add(now, -172_800, :second), now) == "vor 2 Tagen"
    end

    test "gives up on arithmetic past a week and shows a date", %{now: now} do
      Locale.put_locale("en")
      long_ago = DateTime.add(now, -30, :day)

      assert Formats.relative_time(long_ago, now) == Formats.date(long_ago)
    end

    test "shows a date rather than a negative age for a clock skewed forward", %{now: now} do
      Locale.put_locale("en")
      future = DateTime.add(now, 60, :second)

      assert Formats.relative_time(future, now) == Formats.date(future)
    end
  end
end
