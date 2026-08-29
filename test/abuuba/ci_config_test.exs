defmodule Abuuba.CIConfigTest do
  @moduledoc """
  Guards the quality gate itself.

  The gate is only worth what it checks, and both halves are easy to weaken by
  accident: an alias step swapped back to its rewriting variant passes silently,
  and a workflow that stops reading `.tool-versions` builds against whatever
  Erlang the runner happens to ship. These tests fail when either happens.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @workflow_path Path.join(@root, ".github/workflows/ci.yml")
  @tool_versions_path Path.join(@root, ".tool-versions")
  @readme_path Path.join(@root, "README.md")

  @external_resource @workflow_path
  @external_resource @tool_versions_path

  test "mix precommit reports rather than rewrites, so CI can run the same alias" do
    assert Keyword.fetch!(Mix.Project.config()[:aliases], :precommit) == [
             "compile --warnings-as-errors",
             "deps.unlock --check-unused",
             "format --check-formatted",
             "credo --strict",
             "abuuba.gettext.check",
             "test --warnings-as-errors"
           ]
  end

  test "the suite runs no more cases in parallel than the Repo has connections" do
    pool_size = :abuuba |> Application.fetch_env!(Abuuba.Repo) |> Keyword.fetch!(:pool_size)

    assert ExUnit.configuration()[:max_cases] == pool_size
  end

  describe ".tool-versions" do
    setup do
      %{pins: File.read!(@tool_versions_path)}
    end

    test "pins erlang/OTP", %{pins: pins} do
      assert pins =~ ~r/^erlang\s+\d+\.\d+/m
    end

    test "pins elixir together with the OTP release it was built for", %{pins: pins} do
      assert pins =~ ~r/^elixir\s+\d+\.\d+\.\d+-otp-\d+/m
    end

    test "pins an elixir version this project accepts", %{pins: pins} do
      [_, elixir] = Regex.run(~r/^elixir\s+(\d+\.\d+\.\d+)/m, pins)
      requirement = Mix.Project.config()[:elixir]

      assert Version.match?(elixir, requirement),
             "#{elixir} in .tool-versions does not satisfy #{requirement} in mix.exs"
    end
  end

  describe "the CI workflow" do
    setup do
      workflow = YamlElixir.read_from_file!(@workflow_path)
      %{workflow: workflow, job: workflow["jobs"]["precommit"]}
    end

    test "runs on pushes to main and on pull requests", %{workflow: workflow} do
      # YAML 1.1 reads a bare `on` key as the boolean true.
      triggers = workflow["on"] || workflow[true]

      assert triggers["push"]["branches"] == ["main"]
      assert Map.has_key?(triggers, "pull_request")
    end

    test "runs the same gate developers run locally", %{job: job} do
      assert Enum.any?(job["steps"], &(&1["run"] == "mix precommit"))
    end

    test "takes its language versions from the mise pins, as written", %{job: job} do
      step = Enum.find(job["steps"], &String.starts_with?(&1["uses"] || "", "erlef/setup-beam@"))

      assert step, "no erlef/setup-beam step"
      assert step["with"]["version-file"] == ".tool-versions"
      assert step["with"]["version-type"] == "strict"
      refute step["with"]["otp-version"], "an explicit pin here would shadow .tool-versions"
      refute step["with"]["elixir-version"], "an explicit pin here would shadow .tool-versions"
    end

    test "provides a Postgres 16 service for the test run", %{job: job} do
      assert job["services"]["postgres"]["image"] == "postgres:16"
    end
  end

  test "the README carries the CI badge" do
    assert File.read!(@readme_path) =~ "workflows/ci.yml/badge.svg"
  end
end
