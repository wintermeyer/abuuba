defmodule Abuuba.Repo.Migrations.CreateEmailSubscriptionMessages do
  @moduledoc """
  What an account has written to the addresses on its list.

  Kept rather than sent and forgotten. This is the one screen on the server
  that sends mail to people who never signed up here, so what went out, when,
  in whose name and to how many is a record an admin can ask for and the author
  can look back at.

  It also carries the sending. A list is mailed a page at a time, and the
  cursor of how far a message has got lives on the row: a job that dies halfway
  resumes from where the row says rather than from the top, which is what keeps
  a retry from mailing the first ninety addresses twice.
  """

  use Ecto.Migration

  def change do
    create table(:email_subscription_messages) do
      add :account_id, references(:accounts, type: :bigint, on_delete: :delete_all), null: false

      add :subject, :string, null: false
      add :body, :text, null: false

      # How far down the list this message has been sent, as the id of the last
      # subscription mailed. Nothing clever: the list is ordered by id and the
      # cursor only ever moves forward, so a resumed job cannot go backwards
      # over addresses it already wrote to.
      add :sent_through_id, :bigint

      add :recipient_count, :integer, null: false, default: 0
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # The author's own list, newest first, which is the only way anybody reads
    # this table.
    create index(:email_subscription_messages, [:account_id, :id])
  end
end
