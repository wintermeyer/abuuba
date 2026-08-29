defmodule Mix.Tasks.Abuuba.Domains do
  @shortdoc "Domain operations: list, purge"

  @moduledoc """
      mix abuuba.domains list
      mix abuuba.domains purge spam.example --dry-run

  ## list

  Every server this one has heard from, with how many accounts it knows there.
  The answer to "who is actually on the other end of all this", which is not
  the same list as the one somebody blocked.

  ## purge

  Deletes every account from one server and everything hanging off them. For a
  domain that is gone, or one that was blocked and whose rows are still here
  taking up room and turning up in search.

  This is the most destructive thing in these tasks and it is why every one of
  them takes `--dry-run`: the count comes from the same query the deletion
  uses, so what it says is what would go.
  """

  use Mix.Task

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Ops
  alias Abuuba.Repo

  @commands ~w(list purge)

  @switches [dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    Ops.start!()

    {opts, rest, _invalid} = OptionParser.parse(args, switches: @switches)

    case rest do
      ["list" | _rest] -> list()
      ["purge" | domains] -> purge(domains, opts)
      [command | _rest] -> Ops.unknown(command, @commands)
      [] -> Mix.raise("Say what to do: #{Enum.join(@commands, ", ")}")
    end
  end

  defp list do
    from(a in Account,
      where: not is_nil(a.domain),
      group_by: a.domain,
      order_by: [desc: count(a.id)],
      select: {a.domain, count(a.id)}
    )
    |> Repo.all()
    |> Enum.each(fn {domain, count} -> Mix.shell().info("#{count}\t#{domain}") end)
  end

  defp purge([], _opts), do: Mix.raise("Say which domain")

  defp purge(domains, opts) do
    domains = Enum.map(domains, &String.downcase/1)
    query = from(a in Account, where: a.domain in ^domains)

    if Ops.dry_run?(opts) do
      Ops.report(true, Repo.aggregate(query, :count), "account")
    else
      accounts = Repo.all(query)
      total = length(accounts)

      accounts
      |> Enum.with_index(1)
      |> Enum.each(fn {account, index} ->
        Ops.progress(index, total)
        Accounts.delete_account(account)
      end)

      Ops.progress_done()
      Ops.report(false, total, "account")
    end
  end
end
