defmodule Abuuba.Bench.ReportTest do
  use ExUnit.Case, async: true

  alias Abuuba.Bench.Dataset
  alias Abuuba.Bench.Report

  defp run(overrides \\ %{}) do
    Map.merge(
      %{
        generated_at: ~U[2026-08-06 12:00:00Z],
        profile: :small,
        abuuba_version: "0.1.0",
        mastodon_version: "v4.7.0",
        postgres_version: "17.2",
        cpu: "AMD Ryzen 9 7950X",
        cores: 16,
        memory: "64 GB",
        kernel: "Linux 6.12",
        docker: "29.7.1",
        measurements: [
          %{name: "Home timeline p50", unit: "ms", abuuba: 4.2, mastodon: 21.0}
        ]
      },
      overrides
    )
  end

  describe "what a reader needs in order to disagree" do
    test "says which versions ran" do
      # A benchmark result is a claim about somebody else's software. Without
      # the version it is a claim about nothing in particular.
      report = Report.render(run())

      assert report =~ "v4.7.0"
      assert report =~ "0.1.0"
      assert report =~ "17.2"
    end

    test "and on what machine" do
      report = Report.render(run())

      assert report =~ "AMD Ryzen 9 7950X"
      assert report =~ "64 GB"
    end

    test "and against what data, in the same words the seeders used" do
      report = Report.render(run())

      assert report =~ Dataset.describe(:small)
      assert report =~ to_string(Dataset.seed())
    end

    test "and how to run it again" do
      assert Report.render(run()) =~ "mix abuuba.bench"
    end

    test "saying plainly what it does not know" do
      report = Report.render(run(%{cpu: nil, mastodon_version: nil}))

      assert report =~ "unknown"
    end
  end

  describe "the numbers" do
    test "sit next to each other with the ratio spelled out" do
      report = Report.render(run())

      assert report =~ "4.2 ms"
      assert report =~ "21.0 ms"
      assert report =~ "0.2×"
    end

    test "are never boiled down to one figure" do
      # The ratios differ, and a reader who cares about timeline reads is not
      # helped by an average that includes fan-out.
      report =
        Report.render(
          run(%{
            measurements: [
              %{name: "Home timeline p50", unit: "ms", abuuba: 4.0, mastodon: 20.0},
              %{name: "Fan-out to 1k", unit: "ms", abuuba: 90.0, mastodon: 100.0}
            ]
          })
        )

      refute report =~ "times faster"
      assert report =~ "Home timeline p50"
      assert report =~ "Fan-out to 1k"
    end
  end

  describe "a number sampled over time" do
    test "carries the spread of the samples behind it" do
      # A median hides how much the samples disagreed, and that disagreement is
      # the reader's warning that the stack was doing something other than what
      # the label says. An idle run whose samples ran from 0.6% to 86.8% has a
      # median, but it does not have an answer.
      report =
        Report.render(
          run(%{
            measurements: [
              %{
                name: "CPU, whole stack, idle",
                unit: "%",
                abuuba: 3.9,
                abuuba_range: {0.6, 86.8},
                mastodon: 1.3,
                mastodon_range: {1.1, 6.0}
              }
            ]
          })
        )

      assert report =~ "3.9 % (0.6–86.8)"
      assert report =~ "1.3 % (1.1–6.0)"
    end

    test "and a gauge read once does not pretend to have one" do
      # Memory is read, not sampled over a window, so there is no spread to
      # report and inventing one would be noise.
      report =
        Report.render(
          run(%{
            measurements: [
              %{name: "Memory, whole stack, idle", unit: "MB", abuuba: 636.8, mastodon: 1123.8}
            ]
          })
        )

      assert report =~ "636.8 MB"
      refute report =~ "636.8 MB ("
    end
  end

  describe "a measurement that did not run" do
    test "is in the table rather than left out of it" do
      # Silence in a comparison reads as "no difference".
      report =
        Report.render(
          run(%{
            measurements: [
              %{
                name: "Streaming latency",
                unit: "ms",
                abuuba: 3.0,
                mastodon: nil,
                note: "Mastodon's streaming server did not come up"
              }
            ]
          })
        )

      assert report =~ "Streaming latency"
      assert report =~ "not measured"
    end

    test "and the reason is named" do
      report =
        Report.render(
          run(%{
            measurements: [
              %{
                name: "Streaming latency",
                unit: "ms",
                abuuba: 3.0,
                mastodon: nil,
                note: "no server"
              }
            ]
          })
        )

      assert report =~ "Not measured"
      assert report =~ "no server"
    end

    test "and a run with nothing in it says so rather than printing an empty table" do
      assert Report.render(run(%{measurements: []})) =~ "run that failed"
    end
  end

  describe "the dataset" do
    test "is the same list of handles every time, on both sides" do
      # Two runs on two servers have to be the same run, or the comparison is
      # between two different questions.
      assert Dataset.followers(:small) == Dataset.followers(:small)
      assert length(Dataset.followers(:small)) == 1_000
      assert List.first(Dataset.followers(:small)) == "bench000001"
    end

    test "and names nobody who could be a person" do
      assert Enum.all?(Dataset.followers(:small), &String.starts_with?(&1, "bench"))
    end

    test "sized so that the long one has to be asked for" do
      assert :large in Dataset.profiles()
      assert Dataset.profile(:large).followers == 100_000
      assert Dataset.profile(:small).followers == 1_000
    end
  end
end
