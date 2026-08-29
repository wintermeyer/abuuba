defmodule Abuuba.Federation.SelfRoundTripTest do
  @moduledoc """
  A post this server wrote, read back by this server's own parser.

  Both halves are tested, and neither against the other. The serializer is
  checked against what other servers want, the parser against what other
  servers send, and the seam between them -- abuuba talking to abuuba -- is
  exercised nowhere: the interop suite federates against Mastodon and
  GoToSocial, which are forgiving in their own ways and hide anything we emit
  that only they happen to tolerate.

  That is the same shape as the export and its importer, and as the streaming
  publisher whose events no socket had a clause for. Both looked right alone.

  The post is transplanted onto a remote actor before being read back, because
  a server will not accept its own posts as somebody else's; everything else
  about the document is exactly what goes out on the wire.
  """
  use Abuuba.DataCase, async: true

  import Ecto.Query
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Federation.Activity.Announce
  alias Abuuba.Federation.Activity.Create
  alias Abuuba.Federation.Activity.Delete
  alias Abuuba.Federation.Activity.Update
  alias Abuuba.Federation.ResolveStatus
  alias Abuuba.Federation.Serializer
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.Tag

  @remote "remote.example"

  setup do
    author = account_fixture()
    peer = remote_account_fixture(%{domain: @remote, username: "peer"})

    %{author: author, peer: peer}
  end

  # What goes out on the wire, addressed as if the peer had written it.
  defp as_peer(status, peer) do
    {:ok, object} =
      status
      |> Serializer.create()
      |> Map.get("object")
      |> then(&{:ok, &1})

    object
    |> Map.put("id", "https://#{@remote}/objects/#{status.id}")
    |> Map.put("attributedTo", peer.uri)
    |> Map.put("url", "https://#{@remote}/@peer/#{status.id}")
    |> Map.delete("inReplyTo")
  end

  # The activity as it goes out, with the actor moved to the peer so this
  # server will accept it as somebody else's.
  defp activity_as_peer(activity, peer) do
    activity
    |> Map.put("actor", peer.uri)
    |> Map.put("id", "https://#{@remote}/activities/#{System.unique_integer([:positive])}")
  end

  describe "what this server sends about other people's posts" do
    test "a boost comes back as a boost", %{author: author, peer: peer} do
      original = status_fixture(%{account_id: author.id, text: "worth repeating"})
      {:ok, boost} = Statuses.boost(author, original)

      activity = boost |> Serializer.announce() |> activity_as_peer(peer)

      assert :ok = Announce.handle(activity, [])

      assert Repo.get_by(Abuuba.Statuses.Status,
               account_id: peer.id,
               reblog_of_id: original.id
             ),
             "the boost did not come back as one"
    end

    test "and a vote is counted on the poll it names", %{author: author, peer: peer} do
      {:ok, status} =
        Statuses.create_status(
          %{"account_id" => author.id, "text" => "tea or coffee?"},
          poll: %{"options" => ["tea", "coffee"], "expires_in" => 3600, "multiple" => false}
        )

      poll = Statuses.get_poll(status)
      activity = poll |> Serializer.vote(peer, 1) |> activity_as_peer(peer)

      assert :ok = Create.handle(activity, [])

      assert Statuses.get_poll(status).tallies == [0, 1],
             "the vote this server would have sent was not one it can read"
    end

    test "and an edit changes the words rather than adding a post", %{
      author: author,
      peer: peer
    } do
      status = status_fixture(%{account_id: author.id, text: "frist"})
      {:ok, stored} = ResolveStatus.from_document(as_peer(status, peer))

      {:ok, edited} = Statuses.edit_status(status, %{"text" => "first, sorry"})

      activity =
        edited
        |> Serializer.update()
        |> Map.update!("object", fn object ->
          object
          |> Map.put("id", stored.uri)
          |> Map.put("attributedTo", peer.uri)
        end)
        |> activity_as_peer(peer)

      assert :ok = Update.handle(activity, [])

      assert Statuses.get_status_unchecked(stored.id).text =~ "first, sorry"

      assert Repo.aggregate(
               from(s in Status, where: s.account_id == ^peer.id),
               :count
             ) == 1
    end

    test "and a delete takes the post away", %{author: author, peer: peer} do
      # The post has to belong to the peer for the peer to delete it, so it is
      # written here, sent, and read back before being withdrawn.
      status = status_fixture(%{account_id: author.id, text: "never mind"})
      {:ok, stored} = ResolveStatus.from_document(as_peer(status, peer))

      activity =
        status
        |> Serializer.delete()
        |> Map.put("object", %{"id" => stored.uri, "type" => "Tombstone"})
        |> activity_as_peer(peer)

      assert :ok = Delete.handle(activity, [])

      refute Statuses.get_status_unchecked(stored.id),
             "a post this server said to delete was not deleted when it came back"
    end
  end

  describe "a post this server wrote" do
    test "comes back with its words", %{author: author, peer: peer} do
      status = status_fixture(%{account_id: author.id, text: "hello from here"})

      assert {:ok, stored} = ResolveStatus.from_document(as_peer(status, peer))

      assert stored.text =~ "hello from here"
      assert stored.account_id == peer.id
    end

    test "and its content warning, which is what makes it sensitive", %{
      author: author,
      peer: peer
    } do
      status =
        status_fixture(%{
          account_id: author.id,
          text: "the butler did it",
          spoiler_text: "spoilers"
        })

      assert {:ok, stored} = ResolveStatus.from_document(as_peer(status, peer))

      assert stored.spoiler_text == "spoilers"
      assert stored.sensitive
    end

    test "and its language", %{author: author, peer: peer} do
      status = status_fixture(%{account_id: author.id, text: "guten tag", language: "de"})

      assert {:ok, stored} = ResolveStatus.from_document(as_peer(status, peer))

      assert stored.language == "de"
    end

    test "and its audience", %{author: author, peer: peer} do
      for visibility <- [:public, :unlisted, :private] do
        status =
          status_fixture(%{
            account_id: author.id,
            text: "for #{visibility}",
            visibility: visibility
          })

        assert {:ok, stored} = ResolveStatus.from_document(as_peer(status, peer))

        assert stored.visibility == visibility,
               "#{visibility} came back as #{stored.visibility}"
      end
    end

    test "and the hashtags in it", %{author: author, peer: peer} do
      status = status_fixture(%{account_id: author.id, text: "about #gardening today"})

      assert {:ok, stored} = ResolveStatus.from_document(as_peer(status, peer))

      names =
        Tag
        |> join(:inner, [t], st in "statuses_tags", on: st.tag_id == t.id)
        |> where([_t, st], st.status_id == ^stored.id)
        |> select([t], t.name)
        |> Repo.all()

      assert "gardening" in names
    end

    test "and the poll it asked", %{author: author, peer: peer} do
      {:ok, status} =
        Statuses.create_status(
          %{"account_id" => author.id, "text" => "tea or coffee?"},
          poll: %{
            "options" => ["tea", "coffee"],
            "expires_in" => 3600,
            "multiple" => false
          }
        )

      assert {:ok, stored} = ResolveStatus.from_document(as_peer(status, peer))

      poll = Statuses.get_poll(stored)

      assert poll, "the poll did not survive the round trip"

      # Plain strings, which is how a poll made here stores its options too:
      # the parser reads `name` off each `oneOf` entry and keeps the words.
      assert poll.options == ["tea", "coffee"]
      refute poll.multiple
    end
  end
end
