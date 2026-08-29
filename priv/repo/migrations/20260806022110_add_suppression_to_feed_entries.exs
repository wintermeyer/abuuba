defmodule Abuuba.Repo.Migrations.AddSuppressionToFeedEntries do
  use Ecto.Migration

  @moduledoc """
  Which entry is standing in for this one.

  Five people boosting the same post inside somebody's visible window is one
  thing that happened, not five, and a timeline that shows it five times is a
  timeline people scroll past. So the first arrival is shown and the rest are
  kept but hidden behind it.

  Kept rather than dropped, because the one on show can go away: its booster
  can take the boost back, or delete it. When that happens one of the hidden
  ones is promoted, and a boost that was never stored could not be.

  Null means shown. That is the ordinary case by a wide margin, so the column
  is null almost everywhere and the partial index only covers the rows that
  matter.
  """

  def change do
    alter table(:feed_entries) do
      add :hidden_by_status_id, :bigint
    end

    # Promotion asks "what was hidden behind this one", which is the only
    # question this column is ever asked.
    create index(:feed_entries, [:feed_type, :feed_id, :hidden_by_status_id],
             where: "hidden_by_status_id IS NOT NULL",
             name: :feed_entries_hidden_index
           )
  end
end
