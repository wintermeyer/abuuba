defmodule Abuuba.Repo.Migrations.AddNotifiedAtToPolls do
  use Ecto.Migration

  @moduledoc """
  When a poll's closing was announced.

  A worker that looks for closed polls every minute needs to remember which
  ones it has already told people about, or it tells them again on the next
  minute and every minute after that. Null means not yet.

  Indexed as a partial index over the rows the worker actually reads -- polls
  that have an expiry and have not been announced -- because that set stays
  small however many polls the server has ever seen.
  """

  def change do
    alter table(:polls) do
      add :notified_at, :utc_datetime_usec
    end

    create index(:polls, [:expires_at],
             where: "notified_at IS NULL AND expires_at IS NOT NULL",
             name: :polls_awaiting_notification_index
           )
  end
end
