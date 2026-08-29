defmodule Abuuba.Timelines.MaintenanceWorker do
  @moduledoc """
  Keeps `feed_entries` from growing without bound.

  Three jobs, all of them the same shape: find rows nobody will ever read, and
  stop storing them.

  ## Trimming

  A feed keeps its newest few hundred entries. Enforcing that on every insert
  would turn one fan-out row into a write and a delete on the hottest path this
  server has, so a sweeper does it and a feed is allowed to run over in
  between. Nobody scrolls past the cap in the minutes that takes.

  ## Dormant readers

  A feed nobody has opened in a year is rows in the largest table on the server
  held for somebody who is not reading them. Emptying it costs them nothing:
  the first request after they come back answers 206 and queues a rebuild.

  ## Orphans

  A feed is keyed by an account id with no foreign key behind it, deliberately:
  a key would put a lock on `accounts` in the path of every fan-out insert.
  Deleting an account clears its feed directly, and this catches whatever any
  other path leaves behind.

  ## A batch at a time

  Each pass takes what is over the line and stops. One long transaction trying
  to visit every feed on a large server would hold locks while the thing it is
  measuring keeps moving.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  alias Abuuba.Timelines.Feed

  @batch 500

  # Long enough that somebody who reads once a season is not swept, short
  # enough that an abandoned account stops costing storage within the year.
  @dormant_days 180

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    trim()
    clear_dormant()
    clear_orphaned()

    :ok
  end

  @doc """
  How many feeds one pass touches.
  """
  @spec batch() :: pos_integer()
  def batch, do: @batch

  @doc """
  How long somebody has to be away before their feed is dropped.
  """
  @spec dormant_days() :: pos_integer()
  def dormant_days, do: @dormant_days

  defp trim do
    @batch
    |> Feed.over_limit()
    |> Enum.each(fn {type, feed_id} -> Feed.trim(type, feed_id) end)
  end

  defp clear_dormant do
    @dormant_days
    |> Feed.dormant(@batch)
    |> Enum.each(&Feed.clear("home", &1))
  end

  defp clear_orphaned do
    @batch
    |> Feed.orphaned()
    |> Enum.each(fn {type, feed_id} -> Feed.clear(type, feed_id) end)
  end
end
