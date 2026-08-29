defmodule Abuuba.Repo.Migrations.AddKeypairUniqueness do
  use Ecto.Migration

  @moduledoc """
  The same key twice for the same account means nothing.

  There is already an index saying an account has at most one key it signs
  with. This is the weaker, wider statement: whether a key is live, revoked, or
  only the public half we hold for somebody else's actor, one key is one row.

  It exists because the Mastodon import writes keys in batches and is expected
  to be interrupted and run again. Without it, "insert unless it is already
  there" has nothing to check against for the rows the other index does not
  cover, and a second run quietly doubles them.
  """

  def change do
    create unique_index(:keypairs, [:account_id, :public_key])
  end
end
