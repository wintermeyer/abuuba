defmodule Abuuba.DeleteAccountAtomicityTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Moderation.Actions
  alias Abuuba.Relationships
  alias Abuuba.Stats

  describe "deleting a moderator who has written notes" do
    setup do
      author = account_fixture()
      subject = account_fixture()

      :ok = Actions.add_note(author, :account, subject.id, "Seen this pattern before.")

      %{author: author, subject: subject}
    end

    test "succeeds rather than failing on the note", %{author: author} do
      # `moderation_notes.account_id` names the moderator who wrote the note.
      # It was `null: false` behind a foreign key declared `on_delete:
      # :nilify_all`, so the cascade tried to write a NULL the column forbade
      # and Postgres refused the delete with a 23502. Any moderator who had
      # ever written a note could not be removed.
      assert {:ok, _} = Accounts.delete_account(author)
      refute Repo.get(Account, author.id)
    end

    test "leaves the note behind, attributed to nobody", %{author: author, subject: subject} do
      # The note is moderation history and worth more than the name on it.
      {:ok, _} = Accounts.delete_account(author)

      assert [note] = Actions.notes(:account, subject.id)
      assert note.content == "Seen this pattern before."
      assert is_nil(note.account_id)
    end
  end

  describe "the counters an account leaves behind" do
    test "come back down when it goes" do
      # The positive control for the retraction: without it the assertions
      # about a failed delete below would pass just as happily if nothing were
      # ever subtracted at all.
      leaver = account_fixture()
      followed = account_fixture()

      {:ok, _} = Relationships.follow(leaver, followed)
      assert Stats.account_stats(followed.id).followers_count == 1

      {:ok, _} = Accounts.delete_account(leaver)

      assert Stats.account_stats(followed.id).followers_count == 0
    end

    test "stay put when the delete is rolled back" do
      # `delete_account/1` subtracts the account's contribution from everybody
      # else's counters using rows the delete is about to remove, so the two
      # have to be one transaction: a retraction that stood on its own would
      # leave those numbers short with nothing left to recount from. Rolling
      # the enclosing transaction back is the honest way to ask whether the
      # retraction is really tied to the delete.
      leaver = account_fixture()
      followed = account_fixture()

      {:ok, _} = Relationships.follow(leaver, followed)
      assert Stats.account_stats(followed.id).followers_count == 1

      Repo.transaction(fn ->
        {:ok, _} = Accounts.delete_account(leaver)
        Repo.rollback(:changed_my_mind)
      end)

      assert Repo.get(Account, leaver.id)
      assert Stats.account_stats(followed.id).followers_count == 1
    end
  end
end
