defmodule Abuuba.Repo.Migrations.AddAttributionDomainsToAccounts do
  @moduledoc """
  The sites an account allows to name it as the author of a page.

  A link preview credits somebody when the page's markup says
  `fediverse:creator`, and that markup is written by whoever runs the site.
  Without a list to check it against, any site could put anybody's handle in
  its head and be credited to them, on every server that shows the card. This
  is the half that makes the claim mean something: the person has to have named
  the domain first.

  Empty for everybody until they say otherwise, which is the safe direction --
  nobody is credited by accident.
  """
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :attribution_domains, {:array, :string}, null: false, default: []
    end
  end
end
