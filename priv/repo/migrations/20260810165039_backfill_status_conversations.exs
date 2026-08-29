defmodule Abuuba.Repo.Migrations.BackfillStatusConversations do
  @moduledoc """
  Gives a conversation to every post that has none.

  Only a post composed here ever lacked one: the only place a `conversation_id`
  was set on a new post was the compose form, as the parent's, and a post with
  no parent has no parent's. So every thread this server started was one nobody
  could mute, and without this that stays true of every thread that already
  exists.

  Two passes, in this order.

  First the replies, walking up the reply chain to whichever ancestor already
  has a conversation. A thread whose root arrived from another server has one;
  its local replies do not, and they belong in it rather than in a new one.

  Then whatever is still without: each becomes the root of its own
  conversation, and the first pass runs again to bring its replies in. Roots
  first would need the same walk anyway, and doing it this way means the
  expensive recursive step is written once.
  """

  use Ecto.Migration

  # A thread is not deep, but a bug that made one deep should not make this
  # loop for ever.
  @max_depth 200

  def up do
    fill_from_ancestors()
    start_conversations_for_roots()
    fill_from_ancestors()
  end

  # Irreversible, and nothing is lost by that: the column was null because
  # nothing filled it, and putting the nulls back would restore a defect.
  def down, do: :ok

  # Every status without a conversation whose nearest ancestor has one, in as
  # many rounds as it takes for that to stop being true of anybody. One round
  # is one level of the tree, so a thread of depth three settles in three.
  defp fill_from_ancestors(round \\ 1)

  defp fill_from_ancestors(round) when round > @max_depth, do: :ok

  defp fill_from_ancestors(round) do
    %{num_rows: filled} =
      repo().query!("""
      UPDATE statuses s
         SET conversation_id = parent.conversation_id
        FROM statuses parent
       WHERE s.in_reply_to_id = parent.id
         AND s.conversation_id IS NULL
         AND parent.conversation_id IS NOT NULL
      """)

    if filled > 0, do: fill_from_ancestors(round + 1), else: :ok
  end

  # A root is a post that replies to nothing. Deliberately not "a post whose
  # parent has no conversation either" — that describes every post in an
  # unconverted thread, and giving each of them its own would split one thread
  # into as many conversations as it has posts, which is worse than the state
  # this migration exists to fix. The replies get theirs from the walk
  # afterwards.
  #
  # `in_reply_to_id` is nulled when its target is deleted, so a non-null one
  # always has a row behind it and there are no orphans to consider.
  defp start_conversations_for_roots do
    repo().query!("""
    WITH roots AS (
      SELECT s.id
        FROM statuses s
       WHERE s.conversation_id IS NULL
         AND s.in_reply_to_id IS NULL
    ),
    made AS (
      INSERT INTO conversations (inserted_at, updated_at)
      SELECT now(), now() FROM roots
      RETURNING id
    ),
    paired AS (
      SELECT roots.id AS status_id, made.id AS conversation_id
        FROM (SELECT id, row_number() OVER (ORDER BY id) AS n FROM roots) AS roots
        JOIN (SELECT id, row_number() OVER (ORDER BY id) AS n FROM made) AS made
          ON made.n = roots.n
    )
    UPDATE statuses s
       SET conversation_id = paired.conversation_id
      FROM paired
     WHERE s.id = paired.status_id
    """)
  end
end
