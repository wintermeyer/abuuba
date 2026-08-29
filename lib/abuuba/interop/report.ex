defmodule Abuuba.Interop.Report do
  @moduledoc """
  The matrix a sandbox run leaves behind.

  Scenarios down the side, implementations across the top. The useful thing
  about a matrix is the shape of the holes: one column failing everything is a
  server that did not start, one row failing everywhere is abuuba, and a single
  cell is the interesting case.

  ## A scenario that did not run is not a scenario that passed

  Three outcomes, not two. Passed, failed, and not run — the last for a
  scenario an implementation is not asked, or one that could not be attempted
  because something earlier fell over. Collapsing "not run" into either of the
  others is how a suite quietly stops testing something.
  """

  alias Abuuba.Interop.Suite

  @doc """
  Renders a run.

  `results` is a map of `{scenario_id, implementation_id}` to `:pass`, `:fail`,
  or `{:fail, reason}`.
  """
  @spec render(map()) :: String.t()
  def render(run) do
    results = run[:results] || %{}

    """
    # Federation interop

    #{generated_at(run)}

    #{versions(run)}

    ## Matrix

    #{matrix(results)}

    #{skipped(results)}
    #{failures(results)}
    ## What these mean

    Each row is a thing two servers have to agree about. A cell is one run of
    that scenario against one implementation: **pass**, **fail**, `skipped`
    where that server never ran at all, `not run` where the scenario was not
    reached, or **·** for a scenario that implementation is not asked.

    Nothing here is a judgement about the other implementations. A failure is a
    place where abuuba and that server do not agree, and which of the two is
    wrong is a question this suite deliberately does not answer.

    ## Running it

    `test/interop/run.sh`. It needs Docker and takes a while: a server and a
    database for abuuba and for each implementation, and every scenario driven
    over real HTTP.
    """
  end

  ## Sections

  defp generated_at(run) do
    case run[:generated_at] do
      %DateTime{} = at -> "Run #{DateTime.to_iso8601(at)}."
      _unknown -> "Run by `test/interop/run.sh`."
    end
  end

  defp versions(run) do
    case run[:versions] do
      versions when is_map(versions) and map_size(versions) > 0 ->
        rows =
          Enum.map_join(versions, "\n", fn {name, version} -> "| #{name} | #{version} |" end)

        """
        | Implementation | Version |
        | --- | --- |
        #{rows}
        """

      _none ->
        "The versions each server reported are missing from this run."
    end
  end

  defp matrix(results) do
    implementations = Suite.implementations()
    header = Enum.map_join(implementations, " | ", & &1.name)
    divider = Enum.map_join(implementations, " | ", fn _implementation -> ":-:" end)

    rows =
      Enum.map_join(Suite.scenarios(), "\n", fn scenario ->
        cells =
          Enum.map_join(implementations, " | ", &cell(results, scenario, &1))

        "| #{scenario.name} | #{cells} |"
      end)

    """
    | Scenario | #{header} |
    | --- | #{divider} |
    #{rows}
    """
  end

  defp cell(results, scenario, implementation) do
    if Suite.applies?(scenario, implementation.id) do
      outcome(Map.fetch(results, {scenario.id, implementation.id}))
    else
      "·"
    end
  end

  # Four states, not three. "Skipped" is not "failed" — the server never ran,
  # so it disagreed about nothing — and it is not "not run" either, which is
  # for a scenario that was simply never reached.
  defp outcome({:ok, :pass}), do: "pass"
  defp outcome({:ok, {:skip, _reason}}), do: "skipped"
  defp outcome({:ok, _failed}), do: "**fail**"
  defp outcome(:error), do: "not run"

  # One line per implementation, not one per scenario: every cell in a skipped
  # column says the same thing, and sixteen copies of it is the report nobody
  # reads to the end.
  defp skipped(results) do
    skips =
      results
      |> Enum.filter(fn {_key, outcome} -> match?({:skip, _reason}, outcome) end)
      |> Enum.map(fn {{_scenario, implementation}, {:skip, reason}} ->
        {implementation, reason}
      end)
      |> Enum.uniq()
      |> Enum.sort()

    if skips == [] do
      ""
    else
      lines =
        Enum.map_join(skips, "\n", fn {implementation, reason} ->
          "- **#{implementation}**: #{reason}"
        end)

      """
      ## What did not run

      Nothing was measured against these, so their column is neither a pass nor
      a failure.

      #{lines}

      """
    end
  end

  # The reasons, under the matrix rather than inside it: a table cell is not
  # somewhere anybody can read a sentence.
  defp failures(results) do
    failed =
      results
      |> Enum.filter(fn {_key, outcome} ->
        match?({:fail, _reason}, outcome) or outcome == :fail
      end)
      |> Enum.sort()

    if failed == [] do
      ""
    else
      lines =
        Enum.map_join(failed, "\n", fn {{scenario_id, implementation}, outcome} ->
          scenario = Suite.scenario(scenario_id)

          "- **#{scenario && scenario.name}** against #{implementation}: #{reason(outcome)}"
        end)

      """
      ## What failed

      #{lines}

      """
    end
  end

  defp reason({:fail, reason}), do: reason
  defp reason(_bare), do: "no reason was recorded"
end
