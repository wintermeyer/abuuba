defmodule Abuuba.Repo.Migrations.RelaxRemoteAccountLimits do
  @moduledoc """
  A remote account is allowed more profile fields than a local one.

  Four is abuuba's limit on what somebody may put on their own profile here. It
  was being applied to remote actors too, which meant quietly dropping fields
  another server had legitimately published and rendering those accounts
  differently from every other client on the network.

  Fifty is what the reference implementation keeps, and matching it is the
  point: a profile that shows five fields in one client and four in another is
  a difference the account's owner cannot explain and cannot fix.
  """
  use Ecto.Migration

  def up do
    # A display name of 2048 characters does not fit in varchar(255), so the
    # column has to be as wide as what the network is allowed to send. `text`
    # rather than a wider varchar: Postgres stores them identically, and a
    # number in a column type is one more place the limit has to be changed.
    alter table(:accounts) do
      modify :display_name, :text, null: false, default: ""
    end

    drop constraint(:accounts, :accounts_at_most_four_fields)

    create constraint(:accounts, :accounts_field_count,
             check: "jsonb_array_length(fields) <= CASE WHEN domain IS NULL THEN 4 ELSE 50 END"
           )
  end

  def down do
    drop constraint(:accounts, :accounts_field_count)

    create constraint(:accounts, :accounts_at_most_four_fields,
             check: "jsonb_array_length(fields) <= 4"
           )

    alter table(:accounts) do
      modify :display_name, :string, null: false, default: ""
    end
  end
end
