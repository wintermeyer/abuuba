defmodule Abuuba.Repo.Migrations.DropRemoteAuthorHomeFeeds do
  @moduledoc """
  Clears the home-feed rows written for authors on other servers.

  Fan-out used to write one for the author of every post it stored, including
  remote authors. A home feed is what somebody sees when they open this server
  as themselves, so those rows were never readable by anyone: one per remote
  post, in the second-largest table.

  Fan-out no longer writes them. This takes the ones already there, because
  nothing else would: `mix abuuba.feeds clear` walks local accounts, which is
  exactly the set these rows do not belong to.

  Irreversible on purpose rather than by omission. Putting them back would mean
  recreating rows whose only property is that nothing can read them.
  """

  use Ecto.Migration

  # On a server that has federated for a while this is millions of rows, and
  # one statement would hold every row lock and write every WAL record before
  # committing any of it. Deleting in batches keeps each statement short.
  @batch 50_000

  def up do
    delete_batch()
  end

  def down, do: :ok

  defp delete_batch do
    %{num_rows: deleted} =
      repo().query!(
        """
        DELETE FROM feed_entries
         WHERE ctid = ANY(ARRAY(
           SELECT fe.ctid
             FROM feed_entries fe
             JOIN accounts a ON a.id = fe.feed_id
            WHERE fe.feed_type = 'home' AND a.domain IS NOT NULL
            LIMIT #{@batch}))
        """,
        [],
        timeout: :infinity
      )

    if deleted > 0, do: delete_batch(), else: :ok
  end
end
