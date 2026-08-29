defmodule Abuuba.Repo.Migrations.CreateWebhooks do
  @moduledoc """
  Where this server tells another system that something happened.

  What an admin builds their moderation queue, their alerting or their
  spreadsheet on. The events are the ones a moderator cares about — an account
  arrived, a report came in — so the receiving end is usually a moderation tool
  rather than a general integration.

  The delivery log is not optional. A webhook that has quietly stopped working
  looks exactly like a server where nothing has happened, and an admin who
  cannot tell those apart finds out weeks later that the queue they were
  watching was empty because the pipe was broken.
  """

  use Ecto.Migration

  def change do
    create table(:webhooks) do
      add :url, :string, null: false
      add :events, {:array, :string}, null: false, default: []
      add :enabled, :boolean, null: false, default: false

      # Shared with the receiver so it can tell a real delivery from anything
      # else that can reach its URL. Never shown again after it is rotated,
      # because a secret that stays readable is a secret that leaks with the
      # first screenshot.
      add :secret, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webhooks, [:url])

    create table(:webhook_deliveries) do
      add :webhook_id, references(:webhooks, type: :bigint, on_delete: :delete_all), null: false

      add :event, :string, null: false
      add :status, :integer
      add :error, :string
      add :attempt, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:webhook_deliveries, [:webhook_id, :id])
    create index(:webhook_deliveries, [:inserted_at])
  end
end
