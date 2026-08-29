defmodule Abuuba.Repo.Migrations.AddStatusImportedAt do
  use Ecto.Migration

  @moduledoc """
  A post that was written somewhere else and read back in here.

  ## Why it has to be marked

  An imported post is old. It was published years ago on a server that has
  since gone, and it is being written here now. Everything downstream of a new
  post assumes those two times are the same: the fan-out puts it at the top of
  every follower's timeline, and the delivery queue sends it to every server
  that follows the author.

  Neither is wanted. Nobody's followers asked to be shown a decade of somebody
  else's history in one go, and the rest of the fediverse least of all. This
  column is what those two paths read in order to leave it alone.

  ## It is also the honest answer

  The post's original address is gone — it lived on a domain this server is
  not. Anybody looking at it here is looking at a copy, and saying so is better
  than presenting it as though it had always been here.
  """

  def change do
    alter table(:statuses) do
      add :imported_at, :utc_datetime_usec
    end
  end
end
