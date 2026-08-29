defmodule Abuuba.Repo.Migrations.AddQuotesCountToStatusStats do
  use Ecto.Migration

  @moduledoc """
  How many posts quote this one.

  A counter rather than a count, for the same reason the other three are: it is
  read on every render of every post and counted on a handful of writes.
  """

  def change do
    alter table(:status_stats) do
      add :quotes_count, :integer, null: false, default: 0
    end

    create constraint(:status_stats, :status_stats_quotes_count_not_negative,
             check: "quotes_count >= 0"
           )
  end
end
