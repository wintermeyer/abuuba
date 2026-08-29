defmodule Abuuba.InteractionNotificationsTest do
  @moduledoc """
  Being told that somebody noticed you.

  `Notifications.notify/4` is the only thing that writes a notification, and it
  was never called for a favourite, a boost, a follow, a follow request or an
  edit -- so five of the types this server declares, filters, groups, labels
  and writes push titles for were never produced at all. Running it was what
  showed it: the author of a post that had just been favourited, boosted and
  followed had an empty notification list.
  """
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Notifications
  alias Abuuba.Relationships
  alias Abuuba.Statuses

  setup do
    %{author: account_fixture(), reader: account_fixture()}
  end

  defp types(account), do: account |> Notifications.list() |> Enum.map(& &1.type)

  describe "a favourite" do
    test "tells the author", %{author: author, reader: reader} do
      status = status_fixture(%{account_id: author.id, text: "notice me"})

      {:ok, _} = Statuses.favourite(reader, status)

      assert types(author) == ["favourite"]
      assert [%{status_id: id, from_account_id: from}] = Notifications.list(author)
      assert id == status.id
      assert from == reader.id
    end

    test "and not the person who favourited their own post", %{author: author} do
      status = status_fixture(%{account_id: author.id})

      {:ok, _} = Statuses.favourite(author, status)

      assert types(author) == []
    end

    test "and nobody at all when the author is on another server", %{reader: reader} do
      # A row nobody here will ever read. The guard is in `notify/4` rather
      # than at each call site, because the next one would forget it.
      remote = remote_account_fixture(%{username: "faraway", domain: "other.example"})
      status = status_fixture(%{account_id: remote.id, local: false})

      {:ok, _} = Statuses.favourite(reader, status)

      assert types(remote) == []
    end
  end

  describe "a boost" do
    test "tells the author", %{author: author, reader: reader} do
      status = status_fixture(%{account_id: author.id, text: "worth sharing"})

      {:ok, _} = Statuses.boost(reader, status)

      assert types(author) == ["reblog"]
    end

    test "and names the boost, grouped by what was boosted", %{
      author: author,
      reader: reader
    } do
      # The notification's own post is the boost, which is the shape a client
      # reads; the grouping is by the post that was boosted, because twenty
      # boosts of one post are one thing that happened.
      status = status_fixture(%{account_id: author.id})
      {:ok, boost} = Statuses.boost(reader, status)

      assert [notification] = Notifications.list(author)
      assert notification.status_id == boost.id
      assert notification.group_key == "reblog-#{status.id}"
    end
  end

  describe "a follow" do
    test "tells the person followed", %{author: author, reader: reader} do
      {:ok, _} = Relationships.follow(reader, author)

      assert types(author) == ["follow"]
    end

    test "and changing the settings on a follow does not tell them again", %{
      author: author,
      reader: reader
    } do
      # `follow/3` is also how "follow, but not the boosts" arrives, and that
      # must not read as a second follow.
      {:ok, _} = Relationships.follow(reader, author)
      {:ok, _} = Relationships.follow(reader, author, %{show_reblogs: false})

      assert types(author) == ["follow"]
    end

    test "and asking to follow a locked account tells them that instead", %{
      author: author,
      reader: reader
    } do
      {:ok, _request} = Relationships.request_follow(reader, author)

      assert types(author) == ["follow_request"]
    end
  end

  describe "an edit" do
    test "tells whoever boosted the post", %{author: author, reader: reader} do
      status = status_fixture(%{account_id: author.id, text: "before"})
      {:ok, _} = Statuses.boost(reader, status)

      {:ok, _} = Statuses.edit_status(status, %{"text" => "after"})

      assert "update" in types(reader)
    end

    test "and not its own author", %{author: author} do
      status = status_fixture(%{account_id: author.id, text: "before"})

      {:ok, _} = Statuses.edit_status(status, %{"text" => "after"})

      refute "update" in types(author)
    end
  end
end
