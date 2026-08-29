defmodule Abuuba.Accounts.SuggestionsTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Suggestions
  alias Abuuba.Relationships

  # Every assertion below is a negative -- "this person is not suggested" --
  # and a negative passes just as happily when the query returns nothing at
  # all. So each one is set up through the same friend-of-a-friend shape as
  # the positive case above it, and the positive case runs first.
  defp friend_of_a_friend(reader) do
    friend = account_fixture(%{discoverable: true})
    stranger = account_fixture(%{discoverable: true})
    {:ok, _} = Relationships.follow(reader, friend)
    {:ok, _} = Relationships.follow(friend, stranger)
    stranger
  end

  defp suggested_ids(reader), do: reader |> Suggestions.for_account() |> Enum.map(& &1.id)

  describe "for_account/2" do
    test "suggests somebody the people you follow follow" do
      reader = account_fixture()
      stranger = friend_of_a_friend(reader)

      assert stranger.id in suggested_ids(reader)
    end

    test "dismissing somebody who is not there any more is quietly fine" do
      # A stale suggestion in an app, or a second tap on a button whose
      # account has since been deleted. The row names an account, so an id
      # that is not there is a foreign key violation and was a 500 that any
      # client could trigger by being a moment out of date.
      reader = account_fixture()

      assert Suggestions.dismiss(reader, 999_999_999_999_999_999) == :ok
    end

    test "while dismissing somebody real still takes them off the list" do
      # The positive control: a dismissal that silently did nothing would pass
      # the test above just as well.
      reader = account_fixture()
      stranger = friend_of_a_friend(reader)

      assert stranger.id in suggested_ids(reader)

      :ok = Suggestions.dismiss(reader, stranger.id)

      refute stranger.id in suggested_ids(reader)
    end

    test "and not somebody who has moved away" do
      # Suggesting an account somebody migrated off is suggesting one that will
      # never post again. The column is set directly because what is under test
      # is the suggestion query, not the migration that writes it.
      reader = account_fixture()
      stranger = friend_of_a_friend(reader)
      arrived = account_fixture(%{discoverable: true})

      {:ok, _} =
        stranger
        |> Ecto.Changeset.change(moved_to_account_id: arrived.id)
        |> Abuuba.Repo.update()

      refute stranger.id in suggested_ids(reader)
    end

    test "and not somebody who has blocked you" do
      reader = account_fixture()
      stranger = friend_of_a_friend(reader)

      Relationships.block(stranger, reader)

      refute stranger.id in suggested_ids(reader)
    end

    test "and not somebody you have blocked" do
      reader = account_fixture()
      stranger = friend_of_a_friend(reader)

      Relationships.block(reader, stranger)

      refute stranger.id in suggested_ids(reader)
    end

    test "and not somebody on a domain you have blocked" do
      reader = account_fixture()
      friend = account_fixture(%{discoverable: true})
      stranger = account_fixture(%{discoverable: true, domain: "loud.example"})
      {:ok, _} = Relationships.follow(reader, friend)
      {:ok, _} = Relationships.follow(friend, stranger)

      assert stranger.id in suggested_ids(reader)

      {:ok, _} = Relationships.block_domain(reader, "loud.example")

      refute stranger.id in suggested_ids(reader)
    end

    test "and not somebody you have already asked to follow" do
      reader = account_fixture()
      stranger = friend_of_a_friend(reader)

      {:ok, _request} = Relationships.request_follow(reader, stranger)

      refute stranger.id in suggested_ids(reader)
    end
  end
end
