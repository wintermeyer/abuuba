defmodule Abuuba.Repo.Migrations.AddActorSchemeAndCollections do
  @moduledoc """
  Two columns the actor document needs.

  `id_scheme` records which URI shape an account's actor id uses. Mastodon has
  served actors under `/users/:username` for most of its life and under a
  numeric path for some accounts, and an account taken over by the importer has
  to keep answering on whichever one it already published. Other servers stored
  that URI as the account's permanent name, so serving the other shape would
  not redirect them, it would orphan every follow pointing at the old one. New
  accounts here pick the username scheme and stay on it.

  `hide_collections` is a person's choice not to publish who they follow and
  who follows them. Honoured on the collections themselves rather than only in
  the UI, because a collection is a public endpoint any server can fetch.
  """
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :id_scheme, :string, null: false, default: "username"
      add :hide_collections, :boolean, null: false, default: false
    end

    create constraint(:accounts, :accounts_id_scheme_known,
             check: "id_scheme IN ('username', 'numeric')"
           )
  end
end
