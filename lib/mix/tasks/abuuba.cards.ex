defmodule Mix.Tasks.Abuuba.Cards do
  @shortdoc "Preview cards: list what is held, remove what should not be"

  @moduledoc """
  The link previews this server has fetched and kept.

      mix abuuba.cards usage
      mix abuuba.cards remove --domain spam.example --dry-run
      mix abuuba.cards remove --days 365

  ## usage

  How many cards there are and which sites they came from, commonest first.
  The answer to "why does every post from last year still show a preview of a
  domain that has since been sold".

  ## remove

  Cards from one `--domain`, or older than `--days`. A card is a copy of what a
  page said when it was fetched, so a site that has become something else keeps
  advertising its old self here until the card goes. Removing one leaves the
  post and its link alone: the next reader who opens it fetches the page again
  and gets whatever it says now.

  Takes `--dry-run`, and the count it prints comes from the same query the
  deletion uses.
  """

  use Mix.Task

  import Ecto.Query

  alias Abuuba.Ops
  alias Abuuba.PreviewCards.Card
  alias Abuuba.Repo

  @commands ~w(usage remove)

  @switches [domain: :string, days: :integer, dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    Ops.start!()

    {opts, rest, _invalid} = OptionParser.parse(args, switches: @switches)

    case rest do
      ["usage" | _rest] -> usage()
      ["remove" | _rest] -> remove(opts)
      [command | _rest] -> Ops.unknown(command, @commands)
      [] -> Mix.raise("Say what to do: #{Enum.join(@commands, ", ")}")
    end
  end

  defp usage do
    total = Repo.aggregate(Card, :count)

    Mix.shell().info("Preview cards held: #{total}")

    top =
      Card
      |> select([c], {c.provider_name, count(c.id)})
      |> where([c], not is_nil(c.provider_name) and c.provider_name != "")
      |> group_by([c], c.provider_name)
      |> order_by([c], desc: count(c.id))
      |> limit(10)
      |> Repo.all()

    Enum.each(top, fn {provider, count} ->
      Mix.shell().info("  #{count}\t#{provider}")
    end)
  end

  defp remove(opts) do
    query = filtered(opts)

    if Ops.dry_run?(opts) do
      Ops.report(true, Repo.aggregate(query, :count), "preview card")
    else
      {count, _returned} = Repo.delete_all(query)

      Ops.report(false, count, "preview card")
    end
  end

  # One of the two, and never neither: `mix abuuba.cards remove` with no
  # arguments would otherwise mean "delete every preview card on the server",
  # which is not something to do by pressing return in the wrong terminal.
  defp filtered(opts) do
    domain = Keyword.get(opts, :domain)
    days = Keyword.get(opts, :days)

    cond do
      is_binary(domain) and domain != "" -> from(c in Card, where: like(c.url, ^"%//#{domain}/%"))
      is_integer(days) and days > 0 -> older_than(days)
      true -> Mix.raise("Say which ones: --domain example.com or --days 365.")
    end
  end

  defp older_than(days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    from(c in Card, where: c.inserted_at < ^cutoff)
  end
end
