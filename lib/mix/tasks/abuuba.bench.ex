defmodule Mix.Tasks.Abuuba.Bench do
  @shortdoc "Runs the abuuba-versus-Mastodon benchmark and writes a report"

  @moduledoc """
  Measures this server against Mastodon, on your machine, with one command.

      $ mix abuuba.bench                    # 1k followers
      $ mix abuuba.bench --profile medium   # 10k
      $ mix abuuba.bench --profile large    # 100k, and it takes a while

  Needs Docker and nothing else. It starts both servers from their own images,
  seeds them with the same generated dataset, warms them up, measures, tears
  everything down, and writes `bench/results/<profile>.md`.

  ## Why it is worth running yourself

  Every published benchmark is somebody's own numbers on somebody's own
  machine. These are no different, which is exactly why the harness is in the
  repository: the interesting comparison is the one on the hardware you would
  actually run this on, and disagreeing with a number is much easier when you
  can produce your own.

  The rules the harness holds itself to — same Postgres, out-of-the-box
  configuration on both sides, a warm-up before anything is timed — are in
  `bench/README.md`, along with the places where the two stacks genuinely
  differ and why.

  ## Rendering a report on its own

      $ mix abuuba.bench --report-only --raw bench/results/small --out report.md

  For re-rendering after a run, or for a run somebody else's machine produced.
  """

  use Mix.Task

  alias Abuuba.Bench.Dataset
  alias Abuuba.Bench.Report

  @switches [profile: :string, report_only: :boolean, raw: :string, out: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    profile = profile(opts)

    if opts[:report_only] do
      render(profile, opts)
    else
      harness(profile)
    end
  end

  # A size is a follower count or one of the shorthand names; `Dataset` decides
  # which, and the string is carried on as given so the results directory is
  # named after what was asked for.
  defp profile(opts) do
    name = opts[:profile] || "small"

    if Dataset.profile(name) do
      name
    else
      Mix.raise(
        "Unknown size #{name}. A follower count, or one of: " <>
          Enum.join(Dataset.profiles(), ", ")
      )
    end
  end

  # Shelled out rather than reimplemented: bringing up two Docker stacks is a
  # shell script's job, and having the same orchestration in two places is how
  # they stop agreeing.
  defp harness(profile) do
    script = Path.join([File.cwd!(), "bench", "run.sh"])

    unless File.exists?(script) do
      Mix.raise("#{script} is missing. Run this from the root of the repository.")
    end

    case System.cmd("bash", [script, to_string(profile)], into: IO.stream(:stdio, :line)) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("The benchmark stopped with exit status #{status}.")
    end
  end

  defp render(profile, opts) do
    raw = opts[:raw] || Path.join(["bench", "results", to_string(profile)])
    out = opts[:out] || Path.join(["bench", "results", "#{profile}.md"])

    run = %{
      generated_at: DateTime.utc_now(),
      profile: profile,
      abuuba_version: Mix.Project.config()[:version],
      mastodon_version: mastodon_version(),
      postgres_version: read(raw, "postgres-version.txt"),
      cpu: cpu(),
      cores: System.schedulers_online(),
      memory: memory(),
      kernel: kernel(),
      docker: docker(),
      measurements: measurements(raw),
      warnings: warnings(raw)
    }

    File.mkdir_p!(Path.dirname(out))
    File.write!(out, Report.render(run))

    Mix.shell().info("Wrote #{out}")
  end

  ## Reading what the shell scripts left

  # Written by run.sh when a queue would not go quiet inside the drain deadline.
  defp warnings(raw) do
    case File.read(Path.join(raw, "warnings.txt")) do
      {:ok, text} -> text |> String.split("\n", trim: true)
      {:error, _} -> []
    end
  end

  defp measurements(raw) do
    [
      latency(raw, "Home timeline p50", "home", "p50"),
      latency(raw, "Home timeline p99", "home", "p99"),
      fanout(raw),
      latency(raw, "Public timeline p50", "public", "p50"),
      latency(raw, "Public timeline p99", "public", "p99"),
      latency(raw, "Profile page p50 (logged out)", "page", "p50"),
      latency(raw, "Profile page p99 (logged out)", "page", "p99"),
      cpu_per_request(raw),
      startup(raw),
      resource(raw, "Memory, whole stack, idle", "resources-idle", "memory_mb", "MB"),
      resource(raw, "Memory, whole stack, loaded", "resources-loaded", "memory_mb", "MB")
      # "CPU, whole stack, idle" used to be here. Across two profiles it gave
      # 0.75x, 2.29x, 3.60x and 2.91x — the direction flips. They are idle
      # samples of near-idle stacks, where one background tick dominates a tiny
      # denominator, and on a shared host it measures the neighbours. A number
      # that will not reproduce is not a result, so it is not rendered.
    ]
  end

  # What a timeline read costs in CPU rather than in wall clock. A percentage
  # sampled over a second cannot describe a load that finishes in a third of
  # one, and the shipped rate limits forbid simply asking for more of it.
  defp cpu_per_request(raw) do
    %{
      name: "CPU per home timeline request, whole stack",
      unit: "ms",
      abuuba: read_json(raw, "cpu-abuuba.json")["cpu_ms_per_request"],
      mastodon: read_json(raw, "cpu-mastodon.json")["cpu_ms_per_request"],
      note: "the run did not record CPU time for this stack"
    }
  end

  # The one number people mean by "fan-out latency": not how long the API call
  # took, but how long until the last follower could see the post.
  # Restart rather than cold start: the image is pulled and the container
  # exists, so a first deploy is slower than this on both sides. The
  # application tier only, one container against three, which is the difference
  # being measured rather than a handicap. See `measure/startup.sh` for why the
  # asymmetry favours Mastodon.
  defp startup(raw) do
    abuuba = read_json(raw, "startup-abuuba.json")
    mastodon = read_json(raw, "startup-mastodon.json")

    %{
      name: "Restart, until it answers again",
      unit: "ms",
      abuuba: abuuba["ms"],
      mastodon: mastodon["ms"],
      note: abuuba["note"] || mastodon["note"] || "the stack never answered"
    }
  end

  defp fanout(raw) do
    abuuba = read_json(raw, "fanout-abuuba.json")
    mastodon = read_json(raw, "fanout-mastodon.json")

    %{
      name: "Fan-out, until the last follower sees it",
      unit: "ms",
      abuuba: abuuba["ms"],
      mastodon: mastodon["ms"],
      polls: {abuuba["polls"], mastodon["polls"]},
      note: abuuba["note"] || mastodon["note"] || "the post never arrived"
    }
  end

  # A percentile is only worth printing if the requests behind it succeeded. A
  # 429 or a redirect is served far faster than the timeline it refused to
  # render, so a run that measured nothing but error pages produces an
  # impressive number rather than an obvious failure. `http.sh` records what it
  # saw; this refuses to publish a figure it cannot stand behind.
  defp latency(raw, name, file, key) do
    abuuba = read_json(raw, "#{file}-abuuba.json")
    mastodon = read_json(raw, "#{file}-mastodon.json")

    %{
      name: name,
      unit: "ms",
      abuuba: honest(abuuba, key),
      mastodon: honest(mastodon, key),
      note: refusal(abuuba, mastodon)
    }
  end

  defp honest(measurement, key) do
    if (measurement["failed"] || 0) > 0, do: nil, else: measurement[key]
  end

  defp refusal(abuuba, mastodon) do
    case Enum.filter([abuuba, mastodon], &((&1["failed"] || 0) > 0)) do
      [] -> "the run did not produce this file"
      failing -> "requests failed: " <> Enum.map_join(failing, "; ", & &1["codes"])
    end
  end

  defp resource(raw, name, file, key, unit) do
    %{
      name: name,
      unit: unit,
      abuuba: read_json(raw, "#{file}-abuuba.json")[key],
      mastodon: read_json(raw, "#{file}-mastodon.json")[key],
      note: "docker stats produced nothing for this stack"
    }
  end

  defp read_json(raw, name) do
    with {:ok, contents} <- File.read(Path.join(raw, name)),
         {:ok, decoded} <- Jason.decode(contents) do
      decoded
    else
      _missing -> %{}
    end
  end

  defp read(raw, name) do
    case File.read(Path.join(raw, name)) do
      {:ok, contents} -> String.trim(contents)
      _missing -> nil
    end
  end

  ## The machine it ran on

  defp mastodon_version do
    case File.read(Path.join(["bench", "compose", "mastodon.yml"])) do
      {:ok, contents} ->
        case Regex.run(~r{mastodon:(v[\d.]+)}, contents) do
          [_whole, version] -> version
          _unmatched -> nil
        end

      _missing ->
        nil
    end
  end

  defp cpu do
    with {:ok, info} <- File.read("/proc/cpuinfo"),
         [_whole, model] <- Regex.run(~r/model name\s*:\s*(.+)/, info) do
      String.trim(model)
    else
      _unknown -> from_command("sysctl", ["-n", "machdep.cpu.brand_string"])
    end
  end

  defp memory do
    with {:ok, info} <- File.read("/proc/meminfo"),
         [_whole, kilobytes] <- Regex.run(~r/MemTotal:\s*(\d+)/, info) do
      "#{div(String.to_integer(kilobytes), 1024 * 1024)} GB"
    else
      _unknown -> nil
    end
  end

  defp kernel, do: from_command("uname", ["-sr"])

  defp docker do
    from_command("docker", ["version", "--format", "{{.Server.Version}}"])
  end

  defp from_command(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _unavailable -> nil
    end
  rescue
    _no_such_command -> nil
  end
end
