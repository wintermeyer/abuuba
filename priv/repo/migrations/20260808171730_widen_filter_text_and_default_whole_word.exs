defmodule Abuuba.Repo.Migrations.WidenFilterTextAndDefaultWholeWord do
  @moduledoc """
  Filter titles and keywords as long as the reference implementation allows,
  and `whole_word` defaulting the way it does there.

  Both columns were `varchar(255)`. The reference implementation stores text
  and allows 256 characters for a title and 512 for a keyword, so a client
  sending either of those lengths — legitimately, by its own documentation —
  got a Postgres 22001 through the API rather than an answer.

  `whole_word` defaulted to `false` here and defaults to `true` there. A client
  that leaves it out is by far the common case, and the difference is the
  difference between "cat" matching "concatenate" and not: the same filter,
  written by the same person in the same app, behaved differently depending on
  which server they were on.

  Existing rows keep the value they were saved with. Only what a new keyword
  gets when nobody says changes.
  """

  use Ecto.Migration

  def up do
    alter table(:filters) do
      modify :title, :text
    end

    alter table(:filter_keywords) do
      modify :keyword, :text
      modify :whole_word, :boolean, null: false, default: true
    end
  end

  # Cuts anything that used the new room. Without the `USING`, rolling back a
  # server whose users had written a 300-character keyword fails outright with
  # a 22001, which is a rollback that cannot be run at the one moment somebody
  # needs it. Losing the tail of an over-long filter is the lesser harm, and it
  # is what going back to a version that cannot store it means.
  def down do
    execute "ALTER TABLE filters ALTER COLUMN title TYPE varchar(255) USING left(title, 255)"

    execute """
    ALTER TABLE filter_keywords ALTER COLUMN keyword TYPE varchar(255)
    USING left(keyword, 255)
    """

    alter table(:filter_keywords) do
      modify :whole_word, :boolean, null: false, default: false
    end
  end
end
