defmodule Abuuba.DraftsTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Statuses
  alias Abuuba.Statuses.Draft

  setup do
    %{author: account_fixture()}
  end

  describe "keeping what somebody started" do
    test "saves what is in the box", %{author: author} do
      assert {:ok, draft} = Statuses.save_draft(author, %{"text" => "half a thought"})

      assert draft.params["text"] == "half a thought"
      assert draft.account_id == author.id
    end

    test "keeps everything the box holds, not only the words", %{author: author} do
      {:ok, draft} =
        Statuses.save_draft(author, %{
          "text" => "with a warning",
          "spoiler_text" => "spoiler",
          "visibility" => "private",
          "language" => "de"
        })

      assert draft.params["spoiler_text"] == "spoiler"
      assert draft.params["visibility"] == "private"
      assert draft.params["language"] == "de"
    end

    test "writing more updates the same draft rather than making a pile", %{author: author} do
      # Autosave runs while somebody types. One row per keystroke would turn a
      # sentence into a drafts list nobody can use.
      {:ok, draft} = Statuses.save_draft(author, %{"text" => "half"})
      {:ok, same} = Statuses.save_draft(author, %{"text" => "half a thought"}, draft)

      assert same.id == draft.id
      assert same.params["text"] == "half a thought"
      assert length(Statuses.drafts(author)) == 1
    end

    test "refuses to keep an empty box", %{author: author} do
      # Otherwise clicking into the composer and away again leaves a draft.
      assert Statuses.save_draft(author, %{"text" => "   "}) == {:error, :empty}
      assert Statuses.drafts(author) == []
    end

    test "a warning on its own is still something worth keeping", %{author: author} do
      assert {:ok, _} = Statuses.save_draft(author, %{"text" => "", "spoiler_text" => "careful"})
    end

    test "newest first, because that is the one being written", %{author: author} do
      {:ok, older} = Statuses.save_draft(author, %{"text" => "older"})
      {:ok, newer} = Statuses.save_draft(author, %{"text" => "newer"})

      assert Enum.map(Statuses.drafts(author), & &1.id) == [newer.id, older.id]
    end

    test "lists nobody else's", %{author: author} do
      {:ok, _} = Statuses.save_draft(author, %{"text" => "mine"})

      assert Statuses.drafts(account_fixture()) == []
    end

    test "one can be read back on its own", %{author: author} do
      {:ok, draft} = Statuses.save_draft(author, %{"text" => "mine"})

      assert Statuses.get_draft(author, draft.id).id == draft.id
    end

    test "somebody else's cannot", %{author: author} do
      {:ok, draft} = Statuses.save_draft(author, %{"text" => "mine"})

      assert Statuses.get_draft(account_fixture(), draft.id) == nil
    end

    test "discarding forgets it", %{author: author} do
      {:ok, draft} = Statuses.save_draft(author, %{"text" => "never mind"})

      assert {:ok, _} = Statuses.discard_draft(draft)
      assert Statuses.drafts(author) == []
    end
  end

  describe "the ceiling" do
    test "stops a new draft once there are too many", %{author: author} do
      for n <- 1..Draft.limit() do
        {:ok, _} = Statuses.save_draft(author, %{"text" => "draft #{n}"})
      end

      assert Statuses.save_draft(author, %{"text" => "one too many"}) == {:error, :too_many}
    end

    test "still saves the draft already being written", %{author: author} do
      # Refusing here would mean somebody's autosave quietly stops working
      # mid-sentence, which is worse than the pile it is protecting against.
      drafts =
        for n <- 1..Draft.limit() do
          {:ok, draft} = Statuses.save_draft(author, %{"text" => "draft #{n}"})
          draft
        end

      current = List.last(drafts)

      assert {:ok, saved} = Statuses.save_draft(author, %{"text" => "still typing"}, current)
      assert saved.id == current.id
    end

    test "never throws away what somebody wrote to make room", %{author: author} do
      for n <- 1..Draft.limit() do
        {:ok, _} = Statuses.save_draft(author, %{"text" => "draft #{n}"})
      end

      Statuses.save_draft(author, %{"text" => "one too many"})

      assert length(Statuses.drafts(author)) == Draft.limit()
      assert Enum.any?(Statuses.drafts(author), &(&1.params["text"] == "draft 1"))
    end
  end
end
