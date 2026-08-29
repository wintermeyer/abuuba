defmodule Abuuba.Timelines.NotifyOnPostTest do
  @moduledoc """
  "Tell me when this person posts", which is the bell on a follow.

  The switch has been storable since follows had a `notify` column and has
  never done anything. What it means is a notification, and what it must not
  mean is a notification for every reply in every thread that person is in —
  which is the difference between a useful bell and one everybody turns off.
  """

  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Notifications
  alias Abuuba.Relationships

  setup do
    reader = account_fixture()
    author = account_fixture()

    %{reader: reader, author: author}
  end

  defp notifications_of(account) do
    account |> Notifications.list(%{}) |> Enum.filter(&(&1.type == "status"))
  end

  defp watching(reader, author) do
    {:ok, _follow} = Relationships.follow(reader, author, %{notify: true})

    :ok
  end

  describe "with the bell on" do
    setup %{reader: reader, author: author} do
      watching(reader, author)
    end

    test "a post from them is announced", %{reader: reader, author: author} do
      status = status_fixture(%{account_id: author.id, text: "hello"})

      assert [notification] = notifications_of(reader)
      assert notification.status_id == status.id
      assert notification.from_account_id == author.id
    end

    test "a reply of theirs to somebody else is not", %{reader: reader, author: author} do
      # The bell is for what somebody says, not for every conversation they
      # join. Announcing replies is how a bell becomes something to switch off.
      other = account_fixture()
      parent = status_fixture(%{account_id: other.id, text: "a question"})

      status_fixture(%{account_id: author.id, text: "an answer", in_reply_to_id: parent.id})

      assert notifications_of(reader) == []
    end

    test "but a reply to their own post is, because that is a thread", %{
      reader: reader,
      author: author
    } do
      root = status_fixture(%{account_id: author.id, text: "one of two"})
      # Clear the notification for the root so the assertion is about the reply.
      assert [_root_notification] = notifications_of(reader)

      second =
        status_fixture(%{account_id: author.id, text: "two of two", in_reply_to_id: root.id})

      assert second.id in Enum.map(notifications_of(reader), & &1.status_id)
    end

    test "a boost of theirs is not", %{reader: reader, author: author} do
      other = account_fixture()
      original = status_fixture(%{account_id: other.id, text: "somebody else's"})

      {:ok, _boost} = Abuuba.Statuses.boost(author, original)

      assert notifications_of(reader) == []
    end

    test "and a direct message is not, because that is a mention", %{
      reader: reader,
      author: author
    } do
      status_fixture(%{account_id: author.id, text: "just for you", visibility: :direct})

      assert notifications_of(reader) == []
    end
  end

  describe "with the bell off" do
    test "nothing is announced", %{reader: reader, author: author} do
      {:ok, _follow} = Relationships.follow(reader, author)

      status_fixture(%{account_id: author.id, text: "hello"})

      assert notifications_of(reader) == []
    end

    test "which is what following somebody ordinarily means", %{reader: reader, author: author} do
      # The positive control for the switch itself: the same post, the same
      # two accounts, and the only difference is the flag.
      {:ok, _follow} = Relationships.follow(reader, author)
      status_fixture(%{account_id: author.id, text: "first"})

      assert notifications_of(reader) == []

      {:ok, _updated} = Relationships.follow(reader, author, %{notify: true})
      status_fixture(%{account_id: author.id, text: "second"})

      assert [_one] = notifications_of(reader)
    end
  end

  describe "somebody who is not watching" do
    test "hears nothing, whoever else is", %{reader: reader, author: author} do
      watching(reader, author)
      bystander = account_fixture()
      {:ok, _follow} = Relationships.follow(bystander, author)

      status_fixture(%{account_id: author.id, text: "hello"})

      assert [_one] = notifications_of(reader)
      assert notifications_of(bystander) == []
    end
  end
end
