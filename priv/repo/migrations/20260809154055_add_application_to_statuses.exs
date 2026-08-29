defmodule Abuuba.Repo.Migrations.AddApplicationToStatuses do
  @moduledoc """
  Which app a post was written in.

  Clients show it under a post — "via Ivory" — and people use it to tell their
  own scheduled or automated posts apart from the ones they sat down and wrote.
  Nothing recorded it, so every post answered `"application": null` and no
  client could show anything.

  Local posts only. A post from another server arrives with whatever that
  server chose to publish, which is a name and a URL rather than a row here,
  and nothing on the wire carries an id we could point at.

  Nullified rather than cascaded when an app is deleted: the post is still the
  person's, and losing it because a developer removed their client would be
  losing the post to fix a byline.
  """

  use Ecto.Migration

  def change do
    alter table(:statuses) do
      add :application_id, references(:oauth_applications, on_delete: :nilify_all)
    end
  end
end
