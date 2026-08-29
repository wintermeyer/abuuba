defmodule Abuuba.ModerationBroadcastTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Moderation.Actions
  alias Abuuba.Streaming

  setup do
    %{moderator: account_fixture(), target: account_fixture()}
  end

  # Subscribed to the target's own topic rather than the public one: every
  # other async test that deletes a public post also publishes to
  # `public_topic/0`, so a `refute_receive` against it passes alone and fails
  # in a full run for reasons that have nothing to do with moderation.
  describe "a moderator deleting somebody's posts" do
    test "tells everybody watching, when it works", %{moderator: mod, target: target} do
      # The positive control. Without it the refutation below would pass just
      # as happily if moderation never broadcast anything at all.
      status = status_fixture(%{account_id: target.id})
      :ok = Streaming.subscribe(Streaming.account_topic(target))

      {:ok, _strike} =
        Actions.take(mod, target, "delete_statuses", status_ids: [status.id], text: "Spam.")

      assert_receive {:streaming, "delete", %{id: id}}
      assert id == status.id
    end

    test "tells nobody when the strike behind it is refused", %{moderator: mod, target: target} do
      # `apply_action/3` and `record/4` share one transaction so that a
      # suspension cannot exist without a strike to appeal. Deleting a post
      # also broadcasts, and a broadcast does not roll back: if the strike is
      # rejected after the posts are gone, every connected client has already
      # hidden posts that are still in the database and will keep hiding them
      # until the page is reloaded.
      status = status_fixture(%{account_id: target.id})
      :ok = Streaming.subscribe(Streaming.account_topic(target))

      too_long = String.duplicate("a", 5_001)

      assert {:error, _reason} =
               Actions.take(mod, target, "delete_statuses",
                 status_ids: [status.id],
                 text: too_long
               )

      # The post really is still there, so anybody told it was gone was told
      # something untrue.
      refute Repo.reload(status).deleted_at

      refute_receive {:streaming, "delete", _status}, 100
    end
  end
end
