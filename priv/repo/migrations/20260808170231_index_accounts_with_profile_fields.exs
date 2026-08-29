defmodule Abuuba.Repo.Migrations.IndexAccountsWithProfileFields do
  @moduledoc """
  An index for the sweep that re-reads profile links.

  `Abuuba.Accounts.LinkVerification.due/1` wants the local, unsuspended accounts
  that have any fields at all, oldest first. Without an index Postgres reads
  every account row and runs a set-returning function over each one's `fields`
  before it can honour the `LIMIT`, once an hour, usually to find nothing.

  Partial on all three conditions, so the index holds only the accounts that
  can ever match: on a real instance that is a small minority, which makes it
  cheap to keep and cheap to scan. Ordered by `id` because that is the order
  the sweep takes its batch in, so the scan can stop as soon as it has enough
  rather than sorting the whole table first.

  `jsonb_array_length` is immutable, which is what allows it in the predicate
  at all.
  """

  use Ecto.Migration

  # Built without taking a write lock on `accounts`: this table is on the path
  # of every request, and an index build that blocks it is an outage.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:accounts, [:id],
             name: :accounts_with_profile_fields_index,
             where: "domain IS NULL AND suspended_at IS NULL AND jsonb_array_length(fields) > 0",
             concurrently: true
           )
  end
end
