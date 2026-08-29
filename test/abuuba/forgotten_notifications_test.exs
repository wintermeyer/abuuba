defmodule Abuuba.ForgottenNotificationsTest do
  @moduledoc """
  What happens to a notification when the thing it describes is undone.

  Each of these ends with a list that is empty, which a server that never
  wrote a notification in the first place would also produce. So every one of
  them asserts the notification arrived before taking it back, and the last
  test keeps a second, untouched notification alongside so that a version
  which simply emptied the table would fail.
  """
  use Abuuba.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Notifications
  alias Abuuba.Relationships
  alias Abuuba.Statuses

  setup do
    %{author: account_fixture(), reader: account_fixture()}
  end

  defp types(account), do: account |> Notifications.list() |> Enum.map(& &1.type)

  describe "taking back a favourite" do
    test "takes the notification with it", %{author: author, reader: reader} do
      status = status_fixture(%{account_id: author.id})
      {:ok, _} = Statuses.favourite(reader, status)
      assert types(author) == ["favourite"]

      :ok = Statuses.unfavourite(reader, status)

      assert types(author) == []
    end

    test "and not somebody else's favourite of the same post", %{
      author: author,
      reader: reader
    } do
      other = account_fixture()
      status = status_fixture(%{account_id: author.id})
      {:ok, _} = Statuses.favourite(reader, status)
      {:ok, _} = Statuses.favourite(other, status)

      :ok = Statuses.unfavourite(reader, status)

      assert [notification] = Notifications.list(author)
      assert notification.from_account_id == other.id
    end
  end

  describe "taking back a boost" do
    test "takes the notification with it", %{author: author, reader: reader} do
      status = status_fixture(%{account_id: author.id})
      {:ok, _} = Statuses.boost(reader, status)
      assert types(author) == ["reblog"]

      :ok = Statuses.unboost(reader, status)

      assert types(author) == []
    end
  end

  describe "unfollowing" do
    test "takes the notification with it", %{author: author, reader: reader} do
      {:ok, _} = Relationships.follow(reader, author)
      assert types(author) == ["follow"]

      :ok = Relationships.unfollow(reader, author)

      assert types(author) == []
    end

    test "and withdrawing a request takes that one", %{author: author, reader: reader} do
      {:ok, request} = Relationships.request_follow(reader, author)
      assert types(author) == ["follow_request"]

      :ok = Relationships.reject_follow_request(request)

      assert types(author) == []
    end

    test "and a granted request leaves the follow notification standing", %{
      author: author,
      reader: reader
    } do
      # Accepting is not undoing. The request notification goes because the
      # request is gone, and what replaces it is a follow.
      {:ok, request} = Relationships.request_follow(reader, author)

      {:ok, _follow} = Relationships.accept_follow_request(request)

      assert types(author) == ["follow"]
    end
  end

  describe "deleting a post" do
    test "takes the notifications about it", %{author: author, reader: reader} do
      status = status_fixture(%{account_id: author.id})
      other = status_fixture(%{account_id: author.id})
      {:ok, _} = Statuses.favourite(reader, status)
      {:ok, _} = Statuses.favourite(reader, other)

      assert length(Notifications.list(author)) == 2

      {:ok, _} = Statuses.delete_status(status)

      # The one about the other post is untouched, which is what says this
      # removed the right rows rather than all of them.
      assert [notification] = Notifications.list(author)
      assert notification.status_id == other.id
    end

    test "and one whose post went another way is not listed either", %{
      author: author,
      reader: reader
    } do
      # The backstop. A delete can also come from a moderator, from another
      # server, or from a path nobody has written yet, and a list that filters
      # is what catches whatever the removal above misses. Written here by
      # deleting the row behind the notification's back.
      status = status_fixture(%{account_id: author.id})
      kept = status_fixture(%{account_id: author.id})
      {:ok, _} = Statuses.favourite(reader, status)
      {:ok, _} = Statuses.favourite(reader, kept)

      Abuuba.Repo.update_all(
        from(s in Abuuba.Statuses.Status, where: s.id == ^status.id),
        set: [deleted_at: DateTime.utc_now()]
      )

      assert [notification] = Notifications.list(author)
      assert notification.status_id == kept.id
    end

    test "and a mention notification goes with the post that carried it", %{
      author: author,
      reader: reader
    } do
      {:ok, status} =
        Statuses.create_status(%{account_id: reader.id, text: "@#{author.username} hello"})

      assert types(author) == ["mention"]

      {:ok, _} = Statuses.delete_status(status)

      assert types(author) == []
    end
  end
end
