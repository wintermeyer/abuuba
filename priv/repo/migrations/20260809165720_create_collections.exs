defmodule Abuuba.Repo.Migrations.CreateCollections do
  @moduledoc """
  A curated list of accounts that somebody publishes.

  "People I know who write about gardening", handed to a newcomer as one link
  instead of twelve. The thing the fediverse has been doing by hand in a pinned
  post for years, with the difference that being on the list is checkable and
  the people on it can take themselves off.

  ## Being listed is opt-out, not opt-in

  An item is `accepted` as soon as a local account is added, and the account
  can `revoke` it afterwards. Requiring consent first sounds kinder and is
  worse in practice: a starter pack whose twelve entries each need answering
  before anybody sees anything is a starter pack that never launches, and the
  people most worth listing are the least likely to be watching their
  notifications. Revoking is one press and it is permanent — a revoked item is
  kept as a revoked row rather than deleted, so the same person cannot be added
  again by somebody who did not take the hint.

  ## `local` and `uri` are for the collections that arrive later

  A collection from another server is somebody else's document that this one
  displays, exactly as a remote account is. The columns are here from the start
  so the row shape does not change when that lands.
  """

  use Ecto.Migration

  def change do
    create table(:collections) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :description, :text, null: false, default: ""

      # A collection may be about a hashtag, which is what makes it findable by
      # the people who would want it.
      add :tag_id, references(:tags, on_delete: :nilify_all)

      add :sensitive, :boolean, null: false, default: false
      add :discoverable, :boolean, null: false, default: true
      add :language, :string

      # Denormalised because it is on every card. Maintained by the context,
      # never written from a request.
      add :item_count, :integer, null: false, default: 0

      add :local, :boolean, null: false, default: true
      add :uri, :text
      add :url, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:collections, [:account_id])
    create index(:collections, [:tag_id], where: "tag_id IS NOT NULL")
    create unique_index(:collections, [:uri], where: "uri IS NOT NULL")

    create table(:collection_items) do
      add :collection_id, references(:collections, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all)

      add :position, :integer, null: false, default: 1

      # pending, accepted, rejected, revoked. A revoked row is kept rather than
      # deleted: see the module doc.
      add :state, :string, null: false, default: "accepted"

      timestamps(type: :utc_datetime_usec)
    end

    # One row per account per collection, which is what makes "add them again"
    # after a revoke impossible rather than merely discouraged.
    create unique_index(:collection_items, [:collection_id, :account_id],
             where: "account_id IS NOT NULL"
           )

    create index(:collection_items, [:account_id])
  end
end
