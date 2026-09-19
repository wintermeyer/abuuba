defmodule Abuuba.Importer.CLI do
  @moduledoc """
  The import command, with no shell around it.

  A takeover is run on a server, and a server runs a release: the Docker image
  and `rel/` both ship one, and a release has no Mix. So `mix abuuba.import`
  is the front end for a checkout only, `Abuuba.Release.import_mastodon/1` is
  the one for everywhere else, and the command itself lives here so that the
  two cannot answer differently. `switches/0` is the option list both read, for
  the same reason: one of them parsing a flag the other rejects is the drift
  this module exists to prevent.

  Everything comes back as `{:ok, text}` or `{:error, text}`. Deciding what an
  error does — `Mix.raise/1` in a task, a raise that stops `bin/abuuba eval`
  with a non-zero status — belongs to the front end.
  """

  alias Abuuba.Importer
  alias Abuuba.Importer.Checkpoint
  alias Abuuba.Importer.SourceRepo
  alias Abuuba.Release

  @switches [execute: :boolean, reset: :boolean, verify: :boolean, media_root: :string]

  @type option ::
          {:execute, boolean()}
          | {:verify, boolean()}
          | {:reset, boolean()}
          | {:media_root, String.t()}

  @doc """
  Every option the command takes, as `OptionParser` wants them.
  """
  @spec switches() :: keyword()
  def switches, do: @switches

  @doc """
  Runs one import command and says what happened.
  """
  @spec run([option()]) :: {:ok, String.t()} | {:error, String.t()}
  def run(opts \\ []) do
    Release.start_for_command()

    said = if opts[:reset], do: reset(), else: ""

    {outcome, text} =
      with {:ok, config} <- config(opts) do
        if opts[:verify], do: verify(config), else: take_over(config)
      end

    {outcome, said <> text}
  end

  defp reset do
    Checkpoint.reset()

    "Checkpoints cleared; the next run starts from the beginning.\n\n"
  end

  defp config(opts) do
    config =
      [dry_run: !opts[:execute]]
      |> Keyword.merge(Keyword.take(opts, [:media_root]))
      |> Importer.config()

    with {:ok, repo} <- source_repo(config) do
      {:ok, Keyword.put(config, :repo, repo)}
    end
  end

  # A connection opened for this command alone. Not an application repo: the
  # source database is somebody else's, is only ever read, and a repo in the
  # supervision tree would try to connect on every boot forever after.
  #
  # Already started is not a failure. `bin/abuuba eval` is a fresh node every
  # time, but a dry run followed by an `--execute` in one IEx session is not.
  defp source_repo(config) do
    case config[:source_url] do
      url when is_binary(url) and url != "" ->
        case SourceRepo.connect(url) do
          {:ok, _pid} -> {:ok, SourceRepo}
          {:error, {:already_started, _pid}} -> {:ok, SourceRepo}
          {:error, reason} -> {:error, "could not open the source database: #{inspect(reason)}"}
        end

      _ ->
        {:error,
         """
         MASTODON_DATABASE_URL is not set.

         It is the connection string for the instance being taken over, and
         everything this command does starts by reading it.
         """}
    end
  end

  defp take_over(config) do
    case Importer.run(config) do
      {:ok, plan} -> {:ok, Importer.report(plan)}
      {:error, :no_steps} -> {:error, no_steps()}
      {:error, problems} when is_list(problems) -> {:error, problems_message(problems)}
      {:error, {step, reason}} -> {:error, "step #{step} stopped: #{inspect(reason)}"}
    end
  end

  defp verify(config) do
    {:ok, verifications} = Importer.verify(config)

    text = verification(verifications)

    if Enum.any?(verifications, &(&1.failures != [])) do
      {:error, text <> "\nThe import does not check out. Nothing above is a warning.\n"}
    else
      {:ok, text}
    end
  end

  # Whatever the steps reported, in one shape, so that a step added later shows
  # up here without this being edited.
  defp verification(verifications) do
    """
    Verification
    ============

    #{verified(verifications)}
    """
  end

  defp verified([]), do: "No step has anything it can verify."

  defp verified(verifications), do: Enum.map_join(verifications, "\n\n", &one_verification/1)

  defp one_verification(%{name: name, checked: checked, failures: failures}) do
    """
    #{name}: #{checked} checked, #{length(failures)} that do not match
    #{failures(failures)}
    """
  end

  defp failures([]), do: "  all good"

  defp failures(rows), do: Enum.map_join(rows, "\n", &("  " <> inspect(&1)))

  defp problems_message(problems) do
    """
    The import cannot start yet:

    #{Enum.map_join(problems, "\n", fn problem -> "  * #{problem.key}: #{problem.detail}" end)}

    Nothing has been written.
    """
  end

  defp no_steps do
    """
    No import steps are registered, so an --execute run would move nothing.

    They are configuration: see `:import_steps` in config/config.exs. An empty
    list is a misconfiguration rather than a quiet no-op, so this says so
    instead of reporting a successful import of nothing.
    """
  end
end
