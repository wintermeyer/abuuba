defmodule Mix.Tasks.Abuuba.Feeds do
  @shortdoc "Feed operations: build, clear"

  @moduledoc """
      mix abuuba.feeds build
      mix abuuba.feeds build alice
      mix abuuba.feeds clear

  ## build

  Rebuilds home timelines from the posts that should be in them. For after an
  import, after a restore, or after anything that left somebody looking at an
  empty timeline they should not be.

  ## clear

  Empties them. Only worth doing before a build, and it is separate so that
  "empty everybody's timeline" is never something a rebuild does by accident on
  a server where the rebuild then fails.
  """

  use Mix.Task

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Ops
  alias Abuuba.Repo
  alias Abuuba.Timelines
  alias Abuuba.Timelines.Feed

  @commands ~w(build clear)

  @switches [dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    Ops.start!()

    {opts, rest, _invalid} = OptionParser.parse(args, switches: @switches)

    case rest do
      ["build" | names] -> build(names, opts)
      ["clear" | names] -> clear(names, opts)
      [command | _rest] -> Ops.unknown(command, @commands)
      [] -> Mix.raise("Say what to do: #{Enum.join(@commands, ", ")}")
    end
  end

  defp build(names, opts) do
    accounts = accounts(names)
    total = length(accounts)

    unless Ops.dry_run?(opts) do
      accounts
      |> Enum.with_index(1)
      |> Enum.each(fn {account, index} ->
        Ops.progress(index, total)
        Timelines.regenerate(account.id)
      end)

      Ops.progress_done()
    end

    Ops.report(Ops.dry_run?(opts), total, "timeline")
  end

  defp clear(names, opts) do
    accounts = accounts(names)

    unless Ops.dry_run?(opts), do: Enum.each(accounts, &Feed.clear("home", &1.id))

    Ops.report(Ops.dry_run?(opts), length(accounts), "timeline")
  end

  defp accounts([]), do: Repo.all(from a in Account, where: is_nil(a.domain))

  defp accounts(names) do
    names = Enum.map(names, &String.trim_leading(&1, "@"))

    Repo.all(from a in Account, where: is_nil(a.domain) and a.username in ^names)
  end
end
