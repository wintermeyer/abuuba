defmodule Abuuba.Repo.Migrations.CreateSearchIndexes do
  use Ecto.Migration

  @moduledoc """
  Search, in Postgres, with no second datastore to run.

  ## `simple`, not `english`

  A dictionary stems words in one language. A fediverse timeline is many
  languages at once, and stemming German with English rules turns real words
  into ones nobody typed. `simple` folds case and splits on punctuation and
  does nothing else, which is right far more often than any single dictionary
  would be.

  ## Generated columns, not triggers

  Postgres keeps the vector in step with the text itself. A trigger is a second
  place the rule lives and a first place for it to be forgotten when somebody
  writes an `UPDATE` that skips it.

  ## Weights on accounts, trigram beside them

  A display name is what somebody calls themselves and a username is what they
  are addressed as, so a match on the first outranks a match on the second and
  both outrank the domain. That is what `setweight` is for. Full text alone
  cannot answer a half-typed name, though, so a trigram index sits next to it
  for the autocomplete case.
  """

  def change do
    # Trigram matching is what answers "ali" with "alice"; a tsvector cannot,
    # because half a word is not a word.
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm", "DROP EXTENSION IF EXISTS pg_trgm"

    alter table(:accounts) do
      add :searchable, :tsvector,
        generated: """
        ALWAYS AS (
          setweight(to_tsvector('simple', coalesce(display_name, '')), 'A') ||
          setweight(to_tsvector('simple', coalesce(username, '')), 'B') ||
          setweight(to_tsvector('simple', coalesce(domain, '')), 'C')
        ) STORED
        """
    end

    create index(:accounts, [:searchable], using: :gin)

    # `gin_trgm_ops` rather than the default, which is what makes a LIKE with a
    # leading wildcard use an index at all.
    execute """
            CREATE INDEX accounts_username_trgm_index
            ON accounts USING gin (lower(username) gin_trgm_ops)
            """,
            "DROP INDEX IF EXISTS accounts_username_trgm_index"

    execute """
            CREATE INDEX accounts_display_name_trgm_index
            ON accounts USING gin (lower(display_name) gin_trgm_ops)
            """,
            "DROP INDEX IF EXISTS accounts_display_name_trgm_index"

    alter table(:statuses) do
      # The spoiler text is searched with the body: a content warning is words
      # somebody wrote, and leaving it out means a post cannot be found by the
      # only line of it a reader saw.
      add :searchable, :tsvector,
        generated: """
        ALWAYS AS (
          to_tsvector('simple', coalesce(spoiler_text, '') || ' ' || coalesce(text, ''))
        ) STORED
        """
    end

    # Partial: a deleted post is not searchable, and the index has no business
    # carrying rows nothing will ever match against.
    create index(:statuses, [:searchable],
             using: :gin,
             where: "deleted_at IS NULL",
             name: :statuses_searchable_index
           )

    create index(:tags, ["lower(name) gin_trgm_ops"],
             using: :gin,
             name: :tags_name_trgm_index
           )
  end
end
