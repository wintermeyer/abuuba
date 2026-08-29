defmodule Abuuba.Repo.Migrations.CreateTranslationCache do
  use Ecto.Migration

  @moduledoc """
  What a provider said, so it is not asked twice.

  ## Keyed on the words, not on the post

  A hash of what was actually sent plus the language pair. Two posts with the
  same text are one translation, an edited post is a different one without
  anybody having to remember to invalidate anything, and a hundred readers
  asking for the same post cost one call.

  That matters because these calls are metered. A provider bills per character
  and rate limits per minute, and the difference between caching and not is the
  difference between a translate button somebody can press and one that stops
  working at lunchtime.

  ## In Postgres, not in memory

  A cache that empties on restart asks the provider for everything again every
  deploy, which is the one time a server is least able to afford it. Rows carry
  their own expiry and a sweeper takes them; nothing here needs to be fast
  enough to justify losing it.
  """

  def change do
    create table(:translation_cache, primary_key: false) do
      # The hash and the language pair, joined. One column rather than three,
      # because nothing ever queries by part of it.
      add :key, :string, primary_key: true
      add :value, :map, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # The sweeper's only query.
    create index(:translation_cache, [:expires_at])
  end
end
