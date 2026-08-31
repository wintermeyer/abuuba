defmodule Abuuba.MixProject do
  use Mix.Project

  def project do
    [
      app: :abuuba,
      version: "1.0.14",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Abuuba.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  # One release, named after the application. `include_executables_for` is the
  # host's, because the image that builds it is the image that runs it.
  #
  # `runtime_tools` so that an operator can look at a running node without
  # rebuilding it, and `steps` left at the default because a tarball is what
  # the Dockerfile copies out.
  defp releases do
    [
      abuuba: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      # Another server's post arrives as HTML written by somebody we have no
      # reason to trust, and it is rendered into a reader's page. Nothing here
      # hand-rolls that allow-list.
      {:html_sanitize_ex, "~> 1.5"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      # Not test-only any more: preview cards parse other people's HTML, and a
      # real parser is the difference between reading a page and guessing at
      # one with regular expressions.
      {:lazy_html, ">= 0.1.0"},
      {:phoenix_live_dashboard, "~> 0.9.0"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      # The SMTP backend for Swoosh. Not every deployment wants to hand its
      # outgoing mail to an API vendor, and SMTP is the one transport every
      # host already has an answer for.
      {:gen_smtp, "~> 1.2"},
      {:req, "~> 0.5"},
      {:vix, "~> 0.33"},
      {:cc_precompiler, "~> 0.1", runtime: false},
      # Req's transport, named here because delivery configures its own pool
      # rather than taking the default one.
      {:finch, "~> 0.23"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:oban, "~> 2.19"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:bcrypt_elixir, "~> 3.0"},
      {:nimble_totp, "~> 1.0"},
      {:eqrcode, "~> 0.2"},
      {:wax_, "~> 0.6"},
      {:cloak_ecto, "~> 1.3"},
      {:ex_cldr, "~> 2.40"},
      {:ex_cldr_numbers, "~> 2.33"},
      {:ex_cldr_dates_times, "~> 2.20"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:yaml_elixir, "~> 2.11", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind abuuba", "esbuild abuuba"],
      # `compile` first, as in assets.build: colocated hooks are written out by
      # the compiler, so a clean tree has no `phoenix-colocated/abuuba` for
      # tailwind to resolve and the build fails on an import that looks like a
      # missing file. Only a fresh checkout hits it, which is exactly what a
      # release build is.
      "assets.deploy": [
        "compile",
        "tailwind abuuba --minify",
        "esbuild abuuba --minify",
        "phx.digest"
      ],
      # A gate, not a fixer: every step reports rather than rewrites, so the
      # same alias can run unattended in CI and still fail on a stray tab.
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "abuuba.gettext.check",
        # `compile` above never sees the test files themselves, so without this
        # a warning in a test would sail through the gate.
        "test --warnings-as-errors"
      ]
    ]
  end
end
