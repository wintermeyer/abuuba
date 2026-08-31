defmodule Abuuba.Federation.SerializerTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Serializer
  alias Abuuba.Federation.URIs
  alias Abuuba.Media.Upload
  alias Abuuba.Relationships
  alias Abuuba.Statuses

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    author = account_fixture(%{username: "alice"})

    %{author: author, actor: Actor.id(author)}
  end

  defp remote(username, domain) do
    remote_account_fixture(%{
      username: username,
      domain: domain,
      uri: "https://#{domain}/users/#{username}",
      inbox_url: "https://#{domain}/users/#{username}/inbox"
    })
  end

  describe "a note" do
    test "carries what a reader needs and nothing invented", %{author: author, actor: actor} do
      status = status_fixture(%{account_id: author.id, text: "hello"})
      note = Serializer.note(status)

      assert note["type"] == "Note"
      assert note["id"] == "#{actor}/statuses/#{status.id}"
      assert note["attributedTo"] == actor
      assert note["content"] == "<p>hello</p>"
      assert note["published"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end

    test "with a poll goes out as a Question, with the options and the counts", %{
      author: author
    } do
      status = status_fixture(%{account_id: author.id, text: "tea or coffee?"})

      {:ok, _poll} =
        Statuses.create_poll(status, %{
          options: ["tea", "coffee"],
          tallies: [3, 5],
          voters_count: 8,
          expires_at: ~U[2030-01-01 12:00:00.000000Z]
        })

      note = Serializer.note(Statuses.get_status_unchecked(status.id))

      assert note["type"] == "Question"
      assert note["endTime"] == "2030-01-01T12:00:00Z"
      assert note["votersCount"] == 8

      # `oneOf` because it is a single-choice poll. A reader that sees `anyOf`
      # offers checkboxes, so the two are not interchangeable.
      assert [tea, coffee] = note["oneOf"]
      refute Map.has_key?(note, "anyOf")

      assert tea["type"] == "Note"
      assert tea["name"] == "tea"
      assert tea["replies"]["totalItems"] == 3
      assert coffee["replies"]["totalItems"] == 5
    end

    test "and a multiple-choice poll offers anyOf instead", %{author: author} do
      status = status_fixture(%{account_id: author.id, text: "pick some"})

      {:ok, _poll} =
        Statuses.create_poll(status, %{
          options: ["a", "b"],
          multiple: true,
          expires_at: ~U[2030-01-01 12:00:00.000000Z]
        })

      note = Serializer.note(Statuses.get_status_unchecked(status.id))

      assert length(note["anyOf"]) == 2
      refute Map.has_key?(note, "oneOf")
    end

    test "and a finished poll says so, because a reader must not offer to vote", %{
      author: author
    } do
      status = status_fixture(%{account_id: author.id, text: "over"})

      {:ok, _poll} =
        Statuses.create_poll(status, %{
          options: ["a", "b"],
          expires_at: ~U[2020-01-01 12:00:00.000000Z]
        })

      note = Serializer.note(Statuses.get_status_unchecked(status.id))

      assert note["closed"] == "2020-01-01T12:00:00Z"
    end

    test "says who may interact with it, in both spellings of the same policy", %{
      author: author
    } do
      # Two generations of one vocabulary are in the wild and a server reads
      # only the one it knows. GoToSocial 0.19 reads `always` and
      # `approvalRequired`; Mastodon reads `automaticApproval` and
      # `manualApproval`. Publishing only the second is what made every abuuba
      # post unrepliable from GoToSocial: it read the policy, found no `always`
      # under `canReply`, and refused its own user permission to answer.
      status = status_fixture(%{account_id: author.id, visibility: :public})
      policy = Serializer.note(status)["interactionPolicy"]

      for key <- ~w(canLike canReply canAnnounce canQuote) do
        assert policy[key]["always"] == policy[key]["automaticApproval"],
               "#{key} says different things in the two spellings"

        assert policy[key]["approvalRequired"] == policy[key]["manualApproval"]
      end

      assert policy["canReply"]["always"] == [@public]
      assert policy["canLike"]["always"] == [@public]
      assert policy["canAnnounce"]["always"] == [@public]
      assert policy["canQuote"]["always"] == [@public]
    end

    test "and keeps a followers-only post to its followers", %{author: author, actor: actor} do
      status = status_fixture(%{account_id: author.id, visibility: :private})
      policy = Serializer.note(status)["interactionPolicy"]

      assert policy["canReply"]["always"] == ["#{actor}/followers"]
      # Nobody boosts a followers-only post, and saying otherwise invites a
      # peer to try and be refused.
      assert policy["canAnnounce"]["always"] == [actor]
    end

    test "and a post nobody may quote says so without saying nothing", %{
      author: author,
      actor: actor
    } do
      # An empty list is what an unset policy looks like. "Only the author"
      # is how "nobody else" is spelled.
      status =
        status_fixture(%{account_id: author.id, visibility: :public, quote_policy: :nobody})

      policy = Serializer.note(status)["interactionPolicy"]

      assert policy["canQuote"]["always"] == [actor]
      assert policy["canReply"]["always"] == [@public]
    end

    test "addresses the public collection when it is public", %{author: author, actor: actor} do
      status = status_fixture(%{account_id: author.id, visibility: :public})
      note = Serializer.note(status)

      assert @public in note["to"]
      assert "#{actor}/followers" in note["cc"]
    end

    test "swaps to and cc when it is unlisted", %{author: author, actor: actor} do
      # Unlisted is the same reach as public with the public collection moved
      # out of `to`, which is what keeps it off discovery surfaces.
      status = status_fixture(%{account_id: author.id, visibility: :unlisted})
      note = Serializer.note(status)

      assert note["to"] == ["#{actor}/followers"]
      assert @public in note["cc"]
    end

    test "reaches only followers when it is followers-only", %{author: author, actor: actor} do
      status = status_fixture(%{account_id: author.id, visibility: :private})
      note = Serializer.note(status)

      assert note["to"] == ["#{actor}/followers"]
      assert note["cc"] == []
      refute @public in (note["to"] ++ note["cc"])
    end

    test "reaches only the people named when it is direct", %{author: author} do
      status = status_fixture(%{account_id: author.id, visibility: :direct})
      bob = remote("bob", "remote.example")
      {:ok, _} = Statuses.mention(status, bob)

      note = Serializer.note(Abuuba.Repo.reload(status))

      assert note["to"] == [bob.uri]
      assert note["cc"] == []
    end

    test "names everybody it mentions, as a tag and as an address", %{author: author} do
      status = status_fixture(%{account_id: author.id})
      bob = remote("bob", "remote.example")
      {:ok, _} = Statuses.mention(status, bob)

      note = Serializer.note(Abuuba.Repo.reload(status))

      assert bob.uri in note["cc"]

      assert %{"type" => "Mention", "href" => href, "name" => name} =
               Enum.find(note["tag"], &(&1["type"] == "Mention"))

      assert href == bob.uri
      assert name == "@bob@remote.example"
    end

    test "names its hashtags with a link a reader can follow", %{author: author} do
      status = status_fixture(%{account_id: author.id})
      tag = tag_fixture("Caturday")
      :ok = Statuses.tag_status(status, tag)

      note = Serializer.note(Abuuba.Repo.reload(status))

      # The spelling somebody typed, because that is what a reader sees. The
      # link is the casefolded one, since #Caturday and #caturday are one tag
      # and one timeline.
      assert %{"type" => "Hashtag", "name" => "#Caturday", "href" => href} =
               Enum.find(note["tag"], &(&1["type"] == "Hashtag"))

      assert href == "#{URIs.base_url()}/tags/caturday"
    end

    test "and escapes one a peer could not otherwise follow", %{author: author} do
      # A tag may be any word in any script. The Note built its own tag map
      # without the escaping the featured-tags collection does, so the same
      # tag went out encoded on one document and raw on the other -- and a raw
      # one is not a URL.
      status = status_fixture(%{account_id: author.id})
      tag = tag_fixture("Grüße")
      :ok = Statuses.tag_status(status, tag)

      note = Serializer.note(Abuuba.Repo.reload(status))

      assert %{"name" => "#Grüße", "href" => href} =
               Enum.find(note["tag"], &(&1["type"] == "Hashtag"))

      refute href =~ "ü", "the link went out unescaped"
      assert href == Serializer.hashtag(tag)["href"], "and disagreed with the collection"
    end

    test "puts a content warning in summary and marks it sensitive", %{author: author} do
      status =
        status_fixture(%{account_id: author.id, spoiler_text: "spoilers", sensitive: true})

      note = Serializer.note(status)

      assert note["summary"] == "spoilers"
      assert note["sensitive"] == true
    end

    test "leaves out an empty summary rather than sending an empty string", %{author: author} do
      # A peer that renders `summary` when the key is present would show every
      # post as having a content warning of nothing at all.
      note = Serializer.note(status_fixture(%{account_id: author.id}))

      refute Map.has_key?(note, "summary")
    end

    test "points at what it replies to", %{author: author} do
      parent = status_fixture(%{account_id: author.id})
      reply = status_fixture(%{account_id: author.id, in_reply_to_id: parent.id})

      assert Serializer.note(reply)["inReplyTo"] == Serializer.note(parent)["id"]
    end

    test "says inReplyTo is nothing, rather than leaving it out", %{author: author} do
      # An absent key and an explicit null mean the same thing here, and the
      # explicit one is what the network sends.
      note = Serializer.note(status_fixture(%{account_id: author.id}))

      assert Map.has_key?(note, "inReplyTo")
      assert note["inReplyTo"] == nil
    end

    test "declares only the vocabulary it uses", %{author: author} do
      plain = Serializer.note(status_fixture(%{account_id: author.id}))
      [_as, terms] = plain["@context"]

      assert terms["sensitive"] == "as:sensitive"
      refute Map.has_key?(terms, "blurhash")
    end
  end

  describe "the pictures on a note" do
    setup %{author: author} do
      status = status_fixture(%{account_id: author.id, text: "look at this"})

      one =
        Repo.insert!(%Abuuba.Media.Attachment{
          account_id: author.id,
          type: :image,
          processing: :complete,
          file_file_name: "one.png",
          file_content_type: "image/png",
          file_file_size: 1234,
          description: "a cat, asleep",
          blurhash: "LEHV6nWB",
          meta: %{"original" => %{"width" => 640, "height" => 480}},
          remote_url: ""
        })

      two =
        Repo.insert!(%Abuuba.Media.Attachment{
          account_id: author.id,
          type: :image,
          processing: :complete,
          file_file_name: "two.png",
          file_content_type: "image/png",
          remote_url: ""
        })

      {:ok, status} = Abuuba.Media.attach(status, [two.id, one.id])

      %{status: status, one: one, two: two}
    end

    test "travel with it", %{status: status} do
      note = Serializer.note(status)

      # Empty was what every post this server federated carried, so a
      # photograph posted here was text everywhere else.
      assert [first, second] = note["attachment"]
      assert first["type"] == "Document"
      assert second["type"] == "Document"
    end

    test "keep the order their author chose", %{status: status, one: one, two: two} do
      note = Serializer.note(status)

      assert Enum.map(note["attachment"], & &1["url"]) ==
               [Upload.url(two), Upload.url(one)]
    end

    test "carry the alt text, which is the half that matters", %{status: status} do
      note = Serializer.note(status)

      # A picture with no description is a picture some readers cannot read at
      # all, so this is the field a serializer must not drop.
      assert Enum.find(note["attachment"], &(&1["name"] == "a cat, asleep"))
    end

    test "carry what a client needs before the bytes arrive", %{status: status} do
      note = Serializer.note(status)

      described = Enum.find(note["attachment"], &(&1["name"] == "a cat, asleep"))

      assert described["mediaType"] == "image/png"
      assert described["blurhash"] == "LEHV6nWB"
      assert described["width"] == 640
      assert described["height"] == 480
    end

    test "declare the term they use, so nobody compacts it away", %{status: status} do
      note = Serializer.note(status)

      context = note["@context"] |> List.wrap() |> Enum.filter(&is_map/1)

      # A term the context does not declare is one any consumer that compacts
      # the document drops, which makes the field look present and be absent.
      assert Enum.any?(context, &Map.has_key?(&1, "blurhash"))
    end

    test "are absent rather than empty on a post with none", %{author: author} do
      plain = status_fixture(%{account_id: author.id, text: "just words"})

      assert Serializer.note(plain)["attachment"] == []
    end
  end

  describe "a create" do
    test "wraps the note and repeats its audience", %{author: author, actor: actor} do
      status = status_fixture(%{account_id: author.id, visibility: :public})
      create = Serializer.create(status)

      assert create["type"] == "Create"
      assert create["id"] == "#{actor}/statuses/#{status.id}/activity"
      assert create["actor"] == actor
      assert create["object"]["type"] == "Note"

      # A peer that filters on the activity's audience never opens the object,
      # so an activity that does not repeat it delivers to nobody.
      assert create["to"] == create["object"]["to"]
      assert create["cc"] == create["object"]["cc"]
    end

    test "carries the context once, at the top", %{author: author} do
      create = Serializer.create(status_fixture(%{account_id: author.id}))

      assert create["@context"]
      refute Map.has_key?(create["object"], "@context")
    end
  end

  describe "an announce" do
    test "points at the boosted post rather than embedding it", %{author: author, actor: actor} do
      original =
        status_fixture(%{
          account_id: remote("bob", "remote.example").id,
          local: false,
          uri: "https://remote.example/s/1"
        })

      {:ok, boost} = Statuses.boost(author, original)

      announce = Serializer.announce(boost)

      assert announce["type"] == "Announce"
      assert announce["id"] == "#{actor}/statuses/#{boost.id}/activity"
      assert announce["object"] == "https://remote.example/s/1"
    end

    test "credits the boosted author in cc, so they hear about it", %{author: author} do
      other = remote("bob", "remote.example")

      original =
        status_fixture(%{account_id: other.id, local: false, uri: "https://remote.example/s/1"})

      {:ok, boost} = Statuses.boost(author, original)

      assert other.uri in Serializer.announce(boost)["cc"]
    end
  end

  describe "an update and a delete" do
    test "an update names the edit it describes", %{author: author} do
      edited = DateTime.utc_now()
      status = status_fixture(%{account_id: author.id, edited_at: edited})

      update = Serializer.update(status)

      assert update["type"] == "Update"
      assert update["object"]["type"] == "Note"
      assert update["id"] =~ "#updates/#{DateTime.to_unix(edited)}"
    end

    test "a delete leaves a tombstone rather than an empty note", %{author: author} do
      status = status_fixture(%{account_id: author.id})
      delete = Serializer.delete(status)

      assert delete["type"] == "Delete"
      assert delete["id"] == Serializer.note(status)["id"] <> "#delete"
      assert delete["object"]["type"] == "Tombstone"
      assert delete["object"]["id"] == Serializer.note(status)["id"]
      assert @public in delete["to"]
    end

    test "a deleted actor is announced to everybody", %{author: author, actor: actor} do
      delete = Serializer.delete_actor(author)

      assert delete["type"] == "Delete"
      assert delete["id"] == actor <> "#delete"
      assert delete["object"] == actor
      assert delete["to"] == [@public]
    end
  end

  describe "relationship activities" do
    setup do
      %{target: remote("bob", "remote.example")}
    end

    test "a follow names both sides", %{author: author, actor: actor, target: target} do
      {:ok, follow} = Relationships.follow(author, target)
      document = Serializer.follow(follow)

      assert document["type"] == "Follow"
      assert document["id"] == "#{actor}#follows/#{follow.id}"
      assert document["actor"] == actor
      assert document["object"] == target.uri
    end

    test "an undo of a follow names the follow it takes back", %{author: author, target: target} do
      {:ok, follow} = Relationships.follow(author, target)
      undo = Serializer.undo(Serializer.follow(follow))

      assert undo["type"] == "Undo"
      assert undo["id"] == Serializer.follow(follow)["id"] <> "/undo"
      assert undo["actor"] == Serializer.follow(follow)["actor"]
      assert undo["object"]["type"] == "Follow"
    end

    test "an accept wraps the follow it agrees to", %{author: author, target: target} do
      {:ok, request} = Relationships.request_follow(target, author)
      accept = Serializer.accept(request)

      assert accept["type"] == "Accept"
      assert accept["actor"] == Actor.id(author)
      assert accept["object"]["type"] == "Follow"
      assert accept["object"]["actor"] == target.uri
    end

    test "a reject wraps the same follow", %{author: author, target: target} do
      {:ok, request} = Relationships.request_follow(target, author)

      assert Serializer.reject(request)["type"] == "Reject"
    end

    test "an accept and a reject of one request do not share an id", %{
      author: author,
      target: target
    } do
      # A peer that stored the first would read the second as a redelivery and
      # ignore it, so a rejection after an acceptance would never land.
      {:ok, request} = Relationships.request_follow(target, author)

      accept = Serializer.accept(request)
      reject = Serializer.reject(request)

      refute accept["id"] == reject["id"]
      assert reject["id"] =~ "rejects"
    end

    test "a like names the post", %{author: author, actor: actor, target: target} do
      status =
        status_fixture(%{
          account_id: target.id,
          local: false,
          uri: "https://remote.example/s/1"
        })

      {:ok, favourite} = Statuses.favourite(author, status)

      like = Serializer.like(favourite)

      assert like["type"] == "Like"
      assert like["id"] == "#{actor}#likes/#{favourite.id}"
      assert like["object"] == "https://remote.example/s/1"
    end

    test "a block is addressed to the person blocked and nobody else", %{
      author: author,
      target: target
    } do
      # A block is not news for the blocker's followers.
      {:ok, block} = Relationships.block(author, target)
      document = Serializer.block(block)

      assert document["type"] == "Block"
      assert document["object"] == target.uri
      assert document["to"] == [target.uri]
    end
  end

  describe "a move" do
    test "names where the account went", %{author: author, actor: actor} do
      target = remote("bob", "remote.example")

      move = Serializer.move(author, target.uri)

      assert move["type"] == "Move"
      assert move["actor"] == actor
      assert move["object"] == actor
      assert move["target"] == target.uri
    end

    test "has the same id every time, because it is the same move", %{author: author} do
      # An id built from the current clock makes every redelivery look like a
      # fresh move, and a peer that has already followed the pointer once
      # follows it again.
      target = remote("bob", "remote.example")

      assert Serializer.move(author, target.uri)["id"] ==
               Serializer.move(author, target.uri)["id"]
    end
  end

  describe "a flag" do
    test "names the account reported and the posts it is about" do
      target = remote("bob", "remote.example")

      status =
        status_fixture(%{
          account_id: target.id,
          local: false,
          uri: "https://remote.example/s/1"
        })

      flag = Serializer.flag(target, [status], "spam")

      assert flag["type"] == "Flag"
      assert flag["content"] == "spam"
      assert target.uri in flag["object"]
      assert "https://remote.example/s/1" in flag["object"]
    end

    test "is signed by the server, not by the person reporting" do
      # A report that named the reporter would tell the reported account's
      # server who complained about them.
      target = remote("bob", "remote.example")

      assert Serializer.flag(target, [], "spam")["actor"] == "#{URIs.base_url()}/actor"
    end

    test "gets its own id, even two in the same instant" do
      # Two reports about the same account a millisecond apart are two
      # reports. Sharing an id would make the second look like a redelivery of
      # the first and it would never be seen.
      target = remote("bob", "remote.example")

      ids = for _ <- 1..20, do: Serializer.flag(target, [], "spam")["id"]

      assert length(Enum.uniq(ids)) == 20
    end
  end

  describe "featuring a post" do
    test "an add names the post and the collection", %{author: author, actor: actor} do
      status = status_fixture(%{account_id: author.id})

      add = Serializer.add(author, status)

      assert add["type"] == "Add"
      assert add["id"] == "#{actor}#adds/#{status.id}"
      assert add["object"] == Serializer.note(status)["id"]
      assert add["target"] == "#{actor}/collections/featured"
    end

    test "the id is a fragment of the actor, not a URL glued together", %{
      author: author,
      actor: actor
    } do
      # Without the separator this reads as a path under the actor's host that
      # does not exist, and a peer storing it stores a broken reference.
      status = status_fixture(%{account_id: author.id})

      assert Serializer.add(author, status)["id"] =~ "#{actor}#"
      assert Serializer.remove(author, status)["id"] =~ "#{actor}#"
    end

    test "a remove names the same two things", %{author: author, actor: actor} do
      status = status_fixture(%{account_id: author.id})

      remove = Serializer.remove(author, status)

      assert remove["type"] == "Remove"
      assert remove["id"] == "#{actor}#removes/#{status.id}"
      assert remove["object"] == Serializer.note(status)["id"]
      assert remove["target"] == "#{actor}/collections/featured"
    end
  end

  describe "an Update of the actor" do
    test "carries the key, so a reader can still verify what it signs", %{author: author} do
      # The document inside an Update is the actor as somebody else will store
      # it, so it has to be the whole actor. Rendered without the keypair it
      # carried `"publicKey": null`, and GoToSocial refused to convert it --
      # `ExtractPubKeyFromActor: public key property was nil` -- so a profile
      # change from abuuba never showed there. Mastodon tolerated it, which is
      # why this went unnoticed.
      # A local account has a keypair from the moment it is made; the fixture
      # does not bother, so this one gets what production would have given it.
      {:ok, _keypair} = Abuuba.Accounts.create_keypair(author)

      update = Serializer.update_actor(author)

      assert update["type"] == "Update"
      assert update["object"]["id"] == Actor.id(author)
      assert update["object"]["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
      assert update["object"]["publicKey"]["owner"] == Actor.id(author)
    end

    test "and says what changed about the profile", %{author: author} do
      {:ok, author} = Abuuba.Accounts.update_profile(author, %{"display_name" => "A New Name"})

      update = Serializer.update_actor(author)

      assert update["object"]["name"] == "A New Name"
    end
  end
end
