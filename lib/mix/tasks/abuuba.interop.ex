defmodule Mix.Tasks.Abuuba.Interop do
  @shortdoc "Renders the federation interop matrix from a sandbox run"

  @moduledoc """
  Turns what `test/interop/run.sh` recorded into a matrix somebody can read.

      $ mix abuuba.interop --raw test/interop/results/raw --out report.md

  The run itself is a shell script, because it orchestrates four Docker
  containers; this is the part that reads its notes.
  """

  use Mix.Task

  alias Abuuba.Interop.Report
  alias Abuuba.Interop.Suite

  @switches [raw: :string, out: :string, scenarios_for: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    if implementation = opts[:scenarios_for] do
      list_scenarios(implementation)
    else
      write_report(opts)
    end
  end

  # The scenarios that apply to one implementation, one per line, for the
  # runner to read.
  #
  # `applies_to` used to be read only when the report was written, so the
  # runner ran every scenario against every server and a feature a peer does
  # not implement came out as a failure -- which the list itself says is the
  # thing to avoid. Asking here keeps one answer rather than two that drift.
  defp list_scenarios(implementation) do
    implementation
    |> String.to_atom()
    |> Suite.for_implementation()
    |> Enum.each(&IO.puts(&1.id))
  end

  defp write_report(opts) do
    raw = opts[:raw] || Path.join(["test", "interop", "results", "raw"])
    out = opts[:out] || Path.join(["test", "interop", "results", "report.md"])

    run = %{
      generated_at: DateTime.utc_now(),
      versions: versions(raw),
      results: results(raw)
    }

    File.mkdir_p!(Path.dirname(out))
    File.write!(out, Report.render(run))

    Mix.shell().info("Wrote #{out}")
  end

  # One line per scenario per implementation, written as the run went. Read
  # rather than parsed cleverly: the format is three or four words, and a
  # fragile reader here would lose a run somebody waited half an hour for.
  defp results(raw) do
    raw
    |> Path.join("results.txt")
    |> read_lines()
    |> Enum.reduce(%{}, &record/2)
  end

  defp record("PASS " <> rest, results) do
    case String.split(rest, " ", parts: 2) do
      [scenario, implementation] ->
        Map.put(results, {atom(scenario), atom(implementation)}, :pass)

      _unreadable ->
        results
    end
  end

  defp record("FAIL " <> rest, results) do
    case String.split(rest, " ", parts: 3) do
      [scenario, implementation, reason] ->
        Map.put(results, {atom(scenario), atom(implementation)}, {:fail, reason})

      [scenario, implementation] ->
        Map.put(results, {atom(scenario), atom(implementation)}, :fail)

      _unreadable ->
        results
    end
  end

  # One scenario that could say nothing here, because the other server has no
  # way to trigger the thing it tests.
  #
  # Distinct from a pass, and that distinction is the point: a skip exits zero
  # like a pass does, and reporting the two the same way turns "we did not
  # measure this" into "we measured this and it worked", which is the one
  # sentence a report like this must never say by accident.
  defp record("SKIP_SCENARIO " <> rest, results) do
    case String.split(rest, " ", parts: 3) do
      [scenario, implementation, reason] ->
        Map.put(results, {atom(scenario), atom(implementation)}, {:skip, reason})

      [scenario, implementation] ->
        Map.put(results, {atom(scenario), atom(implementation)}, {:skip, "skipped"})

      _unreadable ->
        results
    end
  end

  # A whole implementation that never started, whose image could not be pulled,
  # or whose account could not be made. Recorded against every scenario it was
  # going to be asked, so the column reads as one story rather than sixteen
  # unrelated lines.
  #
  # As a skip rather than a failure. This report exists to say where abuuba and
  # another server disagree, and a server that never ran disagreed about
  # nothing — calling it a failure invents drift that was never measured, and
  # buries any real failure in the same list.
  defp record("SKIP " <> rest, results) do
    case String.split(rest, " ", parts: 2) do
      [implementation, reason] ->
        implementation = atom(implementation)

        implementation
        |> Suite.for_implementation()
        |> Enum.reduce(results, fn scenario, acc ->
          Map.put(acc, {scenario.id, implementation}, {:skip, reason})
        end)

      _unreadable ->
        results
    end
  end

  defp record(_other, results), do: results

  defp versions(raw) do
    raw
    |> Path.join("versions.txt")
    |> read_lines()
    |> Map.new(fn line ->
      case String.split(line, " ", parts: 2) do
        [name, version] -> {name, version}
        [name] -> {name, "unknown"}
      end
    end)
  end

  defp read_lines(path) do
    case File.read(path) do
      {:ok, contents} -> contents |> String.split("\n") |> Enum.reject(&(String.trim(&1) == ""))
      _missing -> []
    end
  end

  # The names come from file names this repository controls, so they are known
  # atoms by the time anything reads them.
  defp atom(name), do: String.to_atom(name)
end
