defmodule Abuuba.Importer.Rebuild do
  @moduledoc """
  The derived data, built from what has just been copied.

  Three kinds of thing are not imported because they are not the source's to
  give:

    * **Home timelines** are a cache of the follow graph. The source keeps them
      in Redis, which a takeover does not read, and they are cheap to rebuild
      from the rows that are now here. Without this every account signs in to
      an empty home timeline and concludes the migration lost their posts.

    * **Counters** came across with the rows they count, so there is nothing to
      do; recounting a hundred million rows to arrive at the same numbers is
      hours for no new information.

    * **The search index** is a generated column in Postgres. It was written by
      the insert, before this step ran.

  ## Through the same function the background job uses

  `Abuuba.Timelines.regenerate/1` is the rule, and it goes through the same
  filtering the fan-out does: blocks, mutes, domain blocks, boost preferences,
  per-follow languages, followed tags. A rebuild with its own idea of what
  belongs in a feed would quietly put posts from blocked accounts into
  somebody's timeline on the day they migrated.
  """

  @behaviour Abuuba.Importer.Step

  import Ecto.Query

  alias Abuuba.Accounts.User
  alias Abuuba.Importer.Checkpoint
  alias Abuuba.Repo
  alias Abuuba.Timelines

  @step "rebuild/home_feeds"

  # Accounts per pass. Each one is several queries for its own timeline, so the
  # batch is about how often the mark moves rather than the size of a statement.
  @batch 100

  @impl Abuuba.Importer.Step
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(_opts) do
    rebuild(Checkpoint.last_id(@step) || 0)
  end

  @doc """
  Whether the accounts that should have a home timeline have one.

  `Abuuba.Timelines.regenerating?/1` decides what "should" means, because it is
  the same question the server answers when somebody opens an empty timeline:
  an account that follows nobody, or that has put everyone it follows into an
  exclusive list, is empty on purpose.
  """
  @impl Abuuba.Importer.Step
  @spec verify(keyword()) :: [Abuuba.Importer.Step.verification()]
  def verify(_opts) do
    accounts = local_account_ids()
    empty = Enum.filter(accounts, &Timelines.regenerating?/1)

    [
      %{
        name: "home timelines",
        checked: length(accounts),
        failures: Enum.map(empty, &%{id: &1, was: "posts to show", now: "empty"})
      }
    ]
  end

  defp local_account_ids do
    User |> select([u], u.account_id) |> Repo.all()
  end

  ## Rebuilding

  defp rebuild(last_id) do
    accounts =
      User
      |> where([u], u.account_id > ^last_id)
      |> order_by([u], asc: u.account_id)
      |> limit(@batch)
      |> select([u], u.account_id)
      |> Repo.all()

    case accounts do
      [] ->
        Checkpoint.finish(@step)

      accounts ->
        Enum.each(accounts, &Timelines.regenerate/1)

        highest = List.last(accounts)
        Checkpoint.record(@step, highest, length(accounts))

        rebuild(highest)
    end
  end
end
