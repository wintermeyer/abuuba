defmodule Mix.Tasks.Abuuba.BenchTest do
  use ExUnit.Case, async: false

  alias Abuuba.Bench.Report

  alias Mix.Tasks.Abuuba.Bench

  setup do
    root = Path.join(System.tmp_dir!(), "abuuba-bench-#{System.unique_integer([:positive])}")
    raw = Path.join(root, "raw")

    File.mkdir_p!(raw)

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, raw: raw}
  end

  defp write!(raw, name, contents), do: File.write!(Path.join(raw, name), contents)

  defp render!(root, raw) do
    out = Path.join(root, "report.md")

    Bench.run(["--report-only", "--raw", raw, "--out", out])

    File.read!(out)
  end

  test "turns what the measurement scripts wrote into a report", %{root: root, raw: raw} do
    write!(raw, "home-abuuba.json", ~s({"p50":4.2,"p99":9.1}))
    write!(raw, "home-mastodon.json", ~s({"p50":21.0,"p99":80.5}))

    report = render!(root, raw)

    assert report =~ "Home timeline p50"
    assert report =~ "4.2 ms"
    assert report =~ "21.0 ms"
  end

  test "and says which measurements produced nothing", %{root: root, raw: raw} do
    # A run that quietly leaves rows out reads as "no difference".
    write!(raw, "home-abuuba.json", ~s({"p50":4.2}))

    report = render!(root, raw)

    assert report =~ "not measured"
    assert report =~ "Not measured"
  end

  test "carries a note from a measurement that gave up", %{root: root, raw: raw} do
    # "It had not arrived after ten minutes" is a result, and the most
    # interesting one this harness can produce.
    write!(raw, "fanout-abuuba.json", ~s({"ms":812.0}))
    write!(raw, "fanout-mastodon.json", ~s({"ms":null,"note":"did not arrive within 600s"}))

    report = render!(root, raw)

    assert report =~ "did not arrive within 600s"
  end

  test "shows the spread of a sampled figure next to its median" do
    # A median whose samples disagreed by two orders of magnitude is the one
    # number a reader most needs warning about: the idle-CPU row once published
    # a 3.0x ratio built out of samples running from 0.6% to 86.8%.
    #
    # That row is gone — it gave four incompatible answers across two profiles
    # and was cut — so this now tests the rendering directly rather than
    # through it. Any sampled measurement added later gets the behaviour, and
    # the reason it exists stays written down.
    report =
      Report.render(%{
        profile: :small,
        warnings: [],
        measurements: [
          %{
            name: "Sampled thing",
            unit: "%",
            abuuba: 3.9,
            abuuba_range: {0.6, 86.8},
            mastodon: 1.3,
            mastodon_range: {1.1, 6.0}
          },
          %{name: "Memory, whole stack, idle", unit: "MB", abuuba: 636.8, mastodon: 1123.8}
        ]
      })

    assert report =~ "3.9 % (0.6–86.8)"
    assert report =~ "1.3 % (1.1–6.0)"
    # A gauge has no spread, and the sampled row's must not leak onto it.
    assert report =~ "636.8 MB"
    refute report =~ "636.8 MB ("
  end

  test "reads the Mastodon version out of the compose file it pins", %{root: root, raw: raw} do
    # The report has to say what it compared against, and the compose file is
    # the only place that knows.
    report = render!(root, raw)

    assert report =~ ~r/\| Mastodon \| v\d+\.\d+\.\d+ \|/
  end

  test "refuses a size nobody defined", %{raw: raw} do
    assert_raise Mix.Error, fn ->
      Bench.run(["--report-only", "--profile", "enormous", "--raw", raw])
    end
  end
end
