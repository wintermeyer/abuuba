defmodule Abuuba.Repo.Migrations.AddPostCleanupToUsers do
  @moduledoc """
  Somebody's standing instruction to delete their own old posts.

  Columns rather than a corner of `settings`, because a worker has to find the
  accounts that want this without reading every user row and decoding a map to
  find out. The partial index is what makes that one query on a server where
  almost nobody has turned it on.
  """

  use Ecto.Migration

  def change do
    alter table(:users) do
      # Null is off, which is the default and stays the default: deleting
      # somebody's posts on a schedule is not something to end up with by
      # accident.
      add :cleanup_after_days, :integer

      # The exceptions, each of which is somebody saying "not that kind".
      add :cleanup_keep_pinned, :boolean, null: false, default: true
      add :cleanup_keep_media, :boolean, null: false, default: false
      add :cleanup_min_favourites, :integer
      add :cleanup_min_boosts, :integer
      add :cleanup_last_run_at, :utc_datetime_usec
    end

    create index(:users, [:cleanup_after_days], where: "cleanup_after_days is not null")
  end
end
