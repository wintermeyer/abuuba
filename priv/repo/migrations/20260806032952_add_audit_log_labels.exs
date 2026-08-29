defmodule Abuuba.Repo.Migrations.AddAuditLogLabels do
  use Ecto.Migration

  @moduledoc """
  Names written into the log entry, so it still reads after the thing is gone.

  An entry that only holds `account_id` and `target_id` says "somebody did
  something to something" the moment either row is deleted, which is exactly
  when the log matters most: an account suspended and then purged, a report
  closed and its author gone. The moderator who reads it a year later is asking
  who did what to whom, and two dangling integers cannot answer that.

  Denormalised on purpose. The handle at the time is also more truthful than a
  join would be: somebody renamed since is not who the entry was written about.
  """

  def change do
    alter table(:audit_log_entries) do
      add :account_handle, :string
      add :target_label, :string
    end
  end
end
