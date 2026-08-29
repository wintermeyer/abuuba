defmodule Abuuba.Repo.Migrations.AddActorFetchTracking do
  @moduledoc """
  When a remote actor was last read, and how many subdomains a host has spent.

  `last_fetched_at` is what makes a refresh possible without re-fetching every
  actor on every mention. A remote profile changes rarely and a fetch costs a
  request to somebody else's server, so knowing when we last looked is the
  difference between polite and abusive.

  `domain_discoveries` is the abuse counter. A single host can otherwise mint
  unlimited subdomains, each carrying an actor, and fill this database with
  accounts that cost us storage and cost them nothing.
  """
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :last_fetched_at, :utc_datetime_usec
    end

    create index(:accounts, [:last_fetched_at], where: "domain IS NOT NULL")

    create table(:domain_discoveries, primary_key: false) do
      # The registrable domain, so that a.evil.example and b.evil.example count
      # against the same budget.
      add :registrable_domain, :string, primary_key: true
      add :subdomain_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end
  end
end
