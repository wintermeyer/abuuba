defmodule Mix.Tasks.Abuuba.InteropTest do
  use ExUnit.Case, async: false

  alias Abuuba.Interop.Suite
  alias Mix.Tasks.Abuuba.Interop

  setup do
    root = Path.join(System.tmp_dir!(), "abuuba-interop-#{System.unique_integer([:positive])}")
    raw = Path.join(root, "raw")

    File.mkdir_p!(raw)

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, raw: raw}
  end

  defp render!(root, raw, results, versions \\ "") do
    File.write!(Path.join(raw, "results.txt"), results)
    File.write!(Path.join(raw, "versions.txt"), versions)

    out = Path.join(root, "report.md")

    Interop.run(["--raw", raw, "--out", out])

    File.read!(out)
  end

  test "reads what the runner wrote, line by line", %{root: root, raw: raw} do
    report =
      render!(root, raw, """
      PASS follow_out mastodon
      FAIL boost akkoma the Announce never arrived
      """)

    assert report =~ "pass"
    assert report =~ "**fail**"
    assert report =~ "the Announce never arrived"
  end

  test "an implementation that never started is skipped, not failed", %{
    root: root,
    raw: raw
  } do
    # The whole point of this report is telling somebody where abuuba and another
    # server disagree. A server that never started disagreed about nothing, and
    # reporting sixteen failures for it invents drift that was never measured.
    report = render!(root, raw, "SKIP gotosocial server-never-started\n")

    assert report =~ "server-never-started"
    assert report =~ "skipped"
    refute report =~ "## What failed"

    for scenario <- Suite.for_implementation(:gotosocial) do
      assert report =~ scenario.name
    end
  end

  test "one scenario that could say nothing is a skip, not a pass", %{root: root, raw: raw} do
    # A skip exits zero exactly as a pass does, and the runner used to print
    # both as "pass". That turns "we did not measure this" into "we measured
    # this and it worked", which is the one thing this report must never say
    # by accident.
    report =
      render!(
        root,
        raw,
        "PASS reply mastodon\nSKIP_SCENARIO quote mastodon this peer cannot make a quote post\n"
      )

    assert report =~ "this peer cannot make a quote post"
    refute report =~ "## What failed"
  end

  test "and a real failure alongside a skip is still reported as a failure", %{
    root: root,
    raw: raw
  } do
    # The positive control: if skips stopped being counted at all, the section
    # would vanish and this file would still be green.
    report =
      render!(
        root,
        raw,
        "SKIP gotosocial image-unavailable\nFAIL reply mastodon it timed out\n"
      )

    assert report =~ "## What failed"
    assert report =~ "it timed out"
    assert report =~ "image-unavailable"
    # And the skipped one is not in among the failures.
    refute report =~ "gotosocial: image-unavailable"
  end

  test "and a scenario nobody ran is neither a pass nor a fail", %{root: root, raw: raw} do
    report = render!(root, raw, "PASS follow_out mastodon\n")

    assert report =~ "not run"
  end

  test "carries the versions each server reported", %{root: root, raw: raw} do
    report = render!(root, raw, "", "Mastodon v4.4.7\nabuuba 0.1.0\n")

    assert report =~ "v4.4.7"
    assert report =~ "0.1.0"
  end

  test "and survives a run that recorded nothing at all", %{root: root, raw: raw} do
    # Half an hour of somebody's time produced an empty file. Saying so beats
    # crashing on it.
    report = render!(root, raw, "")

    assert report =~ "Matrix"
    assert report =~ "not run"
  end
end
