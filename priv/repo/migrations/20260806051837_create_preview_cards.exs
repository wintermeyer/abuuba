defmodule Abuuba.Repo.Migrations.CreatePreviewCards do
  use Ecto.Migration

  @moduledoc """
  What a link turns out to be, and where the answer came from.

  ## One card per address, shared by every post that links it

  A news story shared by two hundred people is one card, not two hundred. The
  join table is what makes that true, and it is also what lets a card be
  refreshed once and be right everywhere.

  The key is the address after redirects. Two shortened links pointing at the
  same story are the same story, and keying on what somebody typed would
  produce a card per shortener.

  ## The endpoint cache is the thing that makes it fast

  Discovering a site's oEmbed endpoint means fetching and parsing its HTML.
  Doing that per link means every article from one newspaper pays for it again,
  where the endpoint is a property of the site and changes about never. Cached
  per host for a day, the second link from a domain costs one request instead
  of two.
  """

  def change do
    create table(:preview_cards) do
      # The address after redirects, which is what makes two shortened links to
      # one story a single card.
      add :url, :text, null: false
      add :title, :text, null: false, default: ""
      add :description, :text, null: false, default: ""
      # "link", "photo" or "video". Never "rich": see `Abuuba.PreviewCards`.
      add :type, :string, null: false, default: "link"

      add :author_name, :string
      add :author_url, :string
      add :provider_name, :string
      add :provider_url, :string

      # The account named by `fediverse:creator`, resolved to somebody real, so
      # a reader can follow the person who wrote the article rather than being
      # shown a handle that may be anybody's claim.
      add :author_account_id, references(:accounts, type: :bigint, on_delete: :nilify_all)

      add :html, :text, null: false, default: ""
      add :width, :integer, null: false, default: 0
      add :height, :integer, null: false, default: 0

      add :image_url, :text
      add :image_description, :text
      add :blurhash, :string
      add :embed_url, :text, null: false, default: ""

      # When it was last read from the site, so a card can be refreshed rather
      # than believed forever.
      add :fetched_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:preview_cards, [:url])

    create table(:preview_cards_statuses, primary_key: false) do
      add :preview_card_id, references(:preview_cards, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :status_id, references(:statuses, type: :bigint, on_delete: :delete_all),
        null: false,
        primary_key: true
    end

    # A status carries one card, and a card is read from its status far more
    # often than the other way round.
    create index(:preview_cards_statuses, [:status_id])

    create table(:oembed_endpoints, primary_key: false) do
      add :host, :string, null: false, primary_key: true
      # Null means "this host has none", which is worth caching too: without it
      # every link to a site without oEmbed pays for the discovery again.
      add :endpoint, :text
      add :format, :string
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
