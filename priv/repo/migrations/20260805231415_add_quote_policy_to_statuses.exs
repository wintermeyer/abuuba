defmodule Abuuba.Repo.Migrations.AddQuotePolicyToStatuses do
  use Ecto.Migration

  @moduledoc """
  Who an author lets quote a given post.

  Until now the answer was derived from visibility alone: public posts were
  quotable and nothing else was. That is a reasonable default and a poor rule,
  because plenty of people post publicly and still do not want their words
  carried off under somebody else's commentary. The column records the choice
  per post, which is where the choice is actually made.
  """

  def change do
    alter table(:statuses) do
      add :quote_policy, :string, null: false, default: "public"
    end

    create constraint(:statuses, :statuses_quote_policy_known,
             check: "quote_policy in ('public', 'followers', 'nobody')"
           )
  end
end
