defmodule Abuuba.NotificationsTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Notifications
  alias Abuuba.Relationships

  setup do
    %{reader: account_fixture(), sender: account_fixture()}
  end

  describe "being told something" do
    test "records who, what and about which post", %{reader: reader, sender: sender} do
      status = status_fixture(%{account_id: sender.id})

      assert {:ok, notification} =
               Notifications.notify(reader, sender, "mention", status_id: status.id)

      assert notification.type == "mention"
      assert notification.from_account_id == sender.id
      assert notification.status_id == status.id
      refute notification.filtered
    end

    test "never tells somebody about their own doing", %{reader: reader} do
      # Somebody favouriting their own post already knows.
      assert Notifications.notify(reader, reader, "favourite") == :ignored
    end

    test "tells them once about one thing that happened", %{reader: reader, sender: sender} do
      # A boost delivered twice is one boost.
      status = status_fixture(%{account_id: reader.id})

      {:ok, _} = Notifications.notify(reader, sender, "reblog", status_id: status.id)
      Notifications.notify(reader, sender, "reblog", status_id: status.id)

      assert length(Notifications.list(reader)) == 1
    end
  end

  describe "who the reader will not hear from" do
    test "somebody muted with notifications hidden", %{reader: reader, sender: sender} do
      # The default when anybody mutes anybody, exported in the archive and
      # read back by the importer -- and never once consulted when deciding
      # whether to ring. Muting somebody who then favourites four things is
      # four notifications from the person you muted.
      {:ok, _} = Relationships.mute(reader, sender, %{hide_notifications: true})

      assert Notifications.notify(reader, sender, "favourite") == {:ok, :dropped}
      assert Notifications.list(reader) == []
    end

    test "but a mute that left notifications on still tells them", %{
      reader: reader,
      sender: sender
    } do
      # The positive control, and the reason the flag exists: muting a timeline
      # is not the same as muting a person, and somebody who asked for one and
      # not the other has to get it.
      {:ok, _} = Relationships.mute(reader, sender, %{hide_notifications: false})

      assert {:ok, _notification} = Notifications.notify(reader, sender, "favourite")
      assert length(Notifications.list(reader)) == 1
    end

    test "somebody blocked", %{reader: reader, sender: sender} do
      {:ok, _} = Relationships.block(reader, sender)

      assert Notifications.notify(reader, sender, "favourite") == {:ok, :dropped}
    end

    test "and anybody on a domain the reader blocked", %{reader: reader} do
      elsewhere =
        remote_account_fixture(%{
          username: "loud",
          domain: "spam.example",
          uri: "https://spam.example/users/loud"
        })

      {:ok, _} = Relationships.block_domain(reader, "spam.example")

      assert Notifications.notify(reader, elsewhere, "favourite") == {:ok, :dropped}
    end
  end

  describe "grouping" do
    test "puts everybody boosting one post on one line", %{reader: reader} do
      status = status_fixture(%{account_id: reader.id})

      for _ <- 1..3 do
        Notifications.notify(reader, account_fixture(), "reblog", status_id: status.id)
      end

      assert [%{notifications: notifications}] = Notifications.grouped(reader)
      assert length(notifications) == 3
    end

    test "keeps boosts of different posts apart", %{reader: reader, sender: sender} do
      one = status_fixture(%{account_id: reader.id})
      two = status_fixture(%{account_id: reader.id})

      Notifications.notify(reader, sender, "reblog", status_id: one.id)
      Notifications.notify(reader, sender, "reblog", status_id: two.id)

      assert length(Notifications.grouped(reader)) == 2
    end

    test "puts follows together, because a client shows them as one line", %{reader: reader} do
      for _ <- 1..3, do: Notifications.notify(reader, account_fixture(), "follow")

      assert [%{notifications: notifications}] = Notifications.grouped(reader)
      assert length(notifications) == 3
    end

    test "one group can be opened on its own", %{reader: reader} do
      status = status_fixture(%{account_id: reader.id})

      {:ok, notification} =
        Notifications.notify(reader, account_fixture(), "reblog", status_id: status.id)

      assert [%{id: id}] = Notifications.group(reader, notification.group_key)
      assert id == notification.id
    end

    test "newest group first", %{reader: reader} do
      Notifications.notify(reader, account_fixture(), "follow")
      status = status_fixture(%{account_id: reader.id})

      {:ok, newer} =
        Notifications.notify(reader, account_fixture(), "reblog", status_id: status.id)

      assert [%{key: key} | _] = Notifications.grouped(reader)
      assert key == newer.group_key
    end
  end

  describe "the policy" do
    test "accepts by default, because a new account hearing from nobody looks broken",
         %{reader: reader, sender: sender} do
      assert {:ok, notification} = Notifications.notify(reader, sender, "mention")
      refute notification.filtered
    end

    test "files a stranger under requests when asked", %{reader: reader, sender: sender} do
      {:ok, _} = Notifications.put_policy(reader, %{"for_not_following" => "filter"})

      assert {:ok, notification} = Notifications.notify(reader, sender, "mention")
      assert notification.filtered
      assert Notifications.list(reader) == []
      assert length(Notifications.list(reader, %{filtered: true})) == 1
    end

    test "lets somebody you follow through the same filter", %{reader: reader, sender: sender} do
      {:ok, _} = Notifications.put_policy(reader, %{"for_not_following" => "filter"})
      {:ok, _} = Relationships.follow(reader, sender)

      assert {:ok, notification} = Notifications.notify(reader, sender, "mention")
      refute notification.filtered
    end

    test "files a stranger's direct message under requests", %{reader: reader, sender: sender} do
      # The default, and the reference implementation's: a private mention is
      # how somebody you have never met puts a message in front of you.
      status = status_fixture(%{account_id: sender.id, visibility: :direct})

      assert {:ok, notification} =
               Notifications.notify(reader, sender, "mention", status_id: status.id)

      assert notification.filtered
    end

    test "and lets one through when it answers something you wrote to them", %{
      reader: reader,
      sender: sender
    } do
      # A conversation you started. Filtering the answer to your own question
      # means going to look in the requests inbox for the reply you are
      # waiting for, which is the opposite of what the axis is for.
      mine =
        status_fixture(%{account_id: reader.id, visibility: :direct, text: "a question"})

      {:ok, _mention} = Abuuba.Statuses.mention(mine, sender)

      theirs =
        status_fixture(%{
          account_id: sender.id,
          visibility: :direct,
          in_reply_to_id: mine.id,
          text: "an answer"
        })

      assert {:ok, notification} =
               Notifications.notify(reader, sender, "mention", status_id: theirs.id)

      refute notification.filtered
    end

    test "but not one that answers somebody else's post", %{reader: reader, sender: sender} do
      # The control for the test above: replying to any post at all must not
      # be enough, or the axis is off for everybody who ever replies.
      other = account_fixture()
      theirs_first = status_fixture(%{account_id: other.id, visibility: :direct})

      theirs =
        status_fixture(%{
          account_id: sender.id,
          visibility: :direct,
          in_reply_to_id: theirs_first.id
        })

      assert {:ok, notification} =
               Notifications.notify(reader, sender, "mention", status_id: theirs.id)

      assert notification.filtered
    end

    test "and follows the thread up past other people's replies", %{
      reader: reader,
      sender: sender
    } do
      # A conversation with more than two people in it is still a conversation
      # the reader started, so the walk does not stop at the first post that
      # is not theirs.
      mine = status_fixture(%{account_id: reader.id, visibility: :direct})
      {:ok, _mention} = Abuuba.Statuses.mention(mine, sender)

      third = account_fixture()

      interjection =
        status_fixture(%{
          account_id: third.id,
          visibility: :direct,
          in_reply_to_id: mine.id
        })

      theirs =
        status_fixture(%{
          account_id: sender.id,
          visibility: :direct,
          in_reply_to_id: interjection.id
        })

      assert {:ok, notification} =
               Notifications.notify(reader, sender, "mention", status_id: theirs.id)

      refute notification.filtered
    end

    test "drops rather than files when asked to", %{reader: reader, sender: sender} do
      {:ok, _} = Notifications.put_policy(reader, %{"for_not_following" => "drop"})

      assert Notifications.notify(reader, sender, "mention") == {:ok, :dropped}
      assert Notifications.list(reader, %{filtered: true}) == []
    end

    test "takes the strictest answer when a sender trips two axes", %{reader: reader} do
      # Somebody who is both brand new and a bot has tripped two, and the
      # person set both for a reason.
      {:ok, _} =
        Notifications.put_policy(reader, %{
          "for_new_accounts" => "filter",
          "for_bots" => "drop"
        })

      bot = account_fixture(%{bot: true})

      assert Notifications.notify(reader, bot, "mention") == {:ok, :dropped}
    end

    test "cannot divert a type that is not about a stranger", %{reader: reader, sender: sender} do
      # Being told your own scheduled post went out is not something anybody
      # asked a stranger for.
      {:ok, _} = Notifications.put_policy(reader, %{"for_not_following" => "drop"})

      assert {:ok, notification} = Notifications.notify(reader, sender, "severed_relationships")
      refute notification.filtered
    end

    test "refuses a decision nobody defined", %{reader: reader} do
      assert {:error, changeset} = Notifications.put_policy(reader, %{"for_bots" => "maybe"})
      assert %{for_bots: [_]} = errors_on(changeset)
    end
  end

  describe "the requests inbox" do
    setup %{reader: reader} do
      {:ok, _} = Notifications.put_policy(reader, %{"for_not_following" => "filter"})

      :ok
    end

    test "lists a sender once, with a count", %{reader: reader, sender: sender} do
      for _ <- 1..3 do
        status = status_fixture(%{account_id: sender.id})
        Notifications.notify(reader, sender, "mention", status_id: status.id)
      end

      assert [request] = Notifications.requests(reader)
      assert request.from_account_id == sender.id
      assert request.notifications_count == 3
    end

    test "accepting moves what was filed and stops filing more", %{
      reader: reader,
      sender: sender
    } do
      # Recording the decision without moving the old ones would leave the
      # person's mentions in a folder they just said they did not want.
      {:ok, _} = Notifications.notify(reader, sender, "mention")

      assert :ok = Notifications.accept_request(reader, sender.id)

      assert length(Notifications.list(reader)) == 1
      assert Notifications.requests(reader) == []
    end

    test "dismissing hides the request and keeps them filtered", %{
      reader: reader,
      sender: sender
    } do
      {:ok, _} = Notifications.notify(reader, sender, "mention")

      assert :ok = Notifications.dismiss_request(reader, sender.id)
      assert Notifications.requests(reader) == []
      assert Notifications.list(reader) == []
      assert length(Notifications.list(reader, %{filtered: true})) == 1
    end

    test "a new notification brings a dismissed request back", %{
      reader: reader,
      sender: sender
    } do
      {:ok, _} = Notifications.notify(reader, sender, "mention")
      :ok = Notifications.dismiss_request(reader, sender.id)

      status = status_fixture(%{account_id: sender.id})
      {:ok, _} = Notifications.notify(reader, sender, "mention", status_id: status.id)

      assert [_request] = Notifications.requests(reader)
    end

    test "accepting somebody nobody filed is not an error", %{reader: reader} do
      assert Notifications.accept_request(reader, account_fixture().id) == {:error, :not_found}
    end
  end

  describe "reading and clearing" do
    setup %{reader: reader, sender: sender} do
      {:ok, one} = Notifications.notify(reader, sender, "follow")
      status = status_fixture(%{account_id: reader.id})
      {:ok, two} = Notifications.notify(reader, account_fixture(), "reblog", status_id: status.id)

      %{one: one, two: two}
    end

    test "newest first", %{reader: reader, one: one, two: two} do
      assert Enum.map(Notifications.list(reader), & &1.id) == [two.id, one.id]
    end

    test "min_id fills the gap from the near end, not the newest page", %{
      reader: reader,
      one: one,
      two: two
    } do
      # `min_id` is a client saying "I have everything up to here" — the page
      # it wants is the one right after that point. `since_id` with the same
      # value wants the newest page instead. Both answers read newest-first.
      {:ok, three} = Notifications.notify(reader, account_fixture(), "follow")

      assert Enum.map(Notifications.list(reader, %{min_id: one.id, limit: 1}), & &1.id) ==
               [two.id]

      assert Enum.map(Notifications.list(reader, %{since_id: one.id, limit: 1}), & &1.id) ==
               [three.id]
    end

    test "can be narrowed to some types", %{reader: reader, one: one} do
      assert Enum.map(Notifications.list(reader, %{types: ["follow"]}), & &1.id) == [one.id]
    end

    test "can have types excluded", %{reader: reader, two: two} do
      assert Enum.map(Notifications.list(reader, %{exclude_types: ["follow"]}), & &1.id) == [
               two.id
             ]
    end

    test "counts what is newer than where somebody read to", %{reader: reader, one: one} do
      assert Notifications.unread_count(reader) == 2
      assert Notifications.unread_count(reader, one.id) == 1
    end

    test "the badge reads the marker itself", %{reader: reader, one: one} do
      # One question, one round trip: the navigation asks this on every page.
      assert Notifications.unread_badge(reader.id) == 2

      {:ok, _} = Abuuba.Timelines.put_marker(reader, "notifications", one.id)

      assert Notifications.unread_badge(reader.id) == 1
    end

    test "stops counting at a thousand", _context do
      # Nobody reads the difference between 1,200 and 4,000, and every client
      # renders both as "99+".
      assert Notifications.unread_cap() == 1000
    end

    test "dismissing forgets one", %{reader: reader, one: one} do
      assert :ok = Notifications.dismiss(reader, one.id)
      refute Notifications.get(reader, one.id)
    end

    test "dismissing somebody else's does nothing", %{one: one} do
      stranger = account_fixture()

      assert :ok = Notifications.dismiss(stranger, one.id)
      assert Notifications.get(one.account_id, one.id)
    end

    test "clearing forgets all of them", %{reader: reader} do
      assert :ok = Notifications.clear(reader)
      assert Notifications.list(reader) == []
    end
  end
end
