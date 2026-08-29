defmodule Abuuba.Federation.ActivityTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Handlers
  alias Abuuba.Federation.Inbox
  alias Abuuba.Federation.Serializer
  alias Abuuba.Federation.URIs
  alias Abuuba.Relationships
  alias Abuuba.Statuses

  @remote_actor "https://remote.example/users/alice"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    remote =
      remote_account_fixture(%{username: "alice", domain: "remote.example", uri: @remote_actor})

    # No `uri:`. A local account never has one in production, and passing
    # one here is what hid the fact that nothing could resolve a local target.
    local = account_fixture(%{username: "local"})

    %{remote: remote, local: local, opts: [resolve_actor: fn _uri -> {:ok, remote} end]}
  end

  defp queued_deliveries do
    Oban.Job
    |> Repo.all()
    |> Enum.filter(&(&1.worker == "Abuuba.Federation.DeliveryWorker"))
    |> Enum.map(& &1.args)
  end

  defp note(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "https://remote.example/statuses/1",
        "type" => "Note",
        "attributedTo" => @remote_actor,
        "content" => "hello",
        "to" => [@public]
      },
      overrides
    )
  end

  defp document(overrides) do
    Map.merge(
      %{
        "type" => "Document",
        "mediaType" => "image/png",
        "url" => "https://remote.example/one.png"
      },
      overrides
    )
  end

  defp create(object_overrides) do
    %{"type" => "Create", "actor" => @remote_actor, "object" => note(object_overrides)}
  end

  defp create_with(document_overrides) do
    create(%{"attachment" => [document(document_overrides)]})
  end

  defp attachments_of(id) do
    "https://remote.example/statuses/#{id}"
    |> Statuses.get_status_unchecked_by_uri()
    |> Abuuba.Media.for_status()
  end

  defp handle(activity, context, extra \\ []) do
    Handlers.handle(activity, Keyword.merge(context.opts, extra))
  end

  describe "Create" do
    test "stores the post", context do
      activity = %{"type" => "Create", "actor" => @remote_actor, "object" => note()}

      assert handle(activity, context) == :ok
      assert Statuses.get_status_unchecked_by_uri("https://remote.example/statuses/1")
    end

    test "keeps the pictures a post arrived with", context do
      activity = %{
        "type" => "Create",
        "actor" => @remote_actor,
        "object" =>
          note(%{
            "attachment" => [
              %{
                "type" => "Document",
                "mediaType" => "image/png",
                "url" => "https://remote.example/media/one.png",
                "name" => "a cat, asleep",
                "blurhash" => "LEHV6nWB",
                "width" => 640,
                "height" => 480
              }
            ]
          })
      }

      assert handle(activity, context) == :ok

      status = Statuses.get_status_unchecked_by_uri("https://remote.example/statuses/1")
      assert [attachment] = Abuuba.Media.for_status(status)

      assert attachment.remote_url == "https://remote.example/media/one.png"
      assert attachment.description == "a cat, asleep"
      assert attachment.blurhash == "LEHV6nWB"
      assert attachment.type == :image
      assert status.ordered_media_attachment_ids == [attachment.id]
    end

    test "keeps them in the order the sender listed", context do
      activity = %{
        "type" => "Create",
        "actor" => @remote_actor,
        "object" =>
          note(%{
            "attachment" => [
              %{
                "type" => "Document",
                "mediaType" => "image/png",
                "url" => "https://remote.example/a.png"
              },
              %{
                "type" => "Document",
                "mediaType" => "image/png",
                "url" => "https://remote.example/b.png"
              }
            ]
          })
      }

      assert handle(activity, context) == :ok

      status = Statuses.get_status_unchecked_by_uri("https://remote.example/statuses/1")

      assert Enum.map(Abuuba.Media.for_status(status), & &1.remote_url) ==
               ["https://remote.example/a.png", "https://remote.example/b.png"]
    end

    test "reads the kind from the media type", context do
      activity = %{
        "type" => "Create",
        "actor" => @remote_actor,
        "object" =>
          note(%{
            "attachment" => [
              %{
                "type" => "Document",
                "mediaType" => "video/mp4",
                "url" => "https://remote.example/v.mp4"
              },
              %{
                "type" => "Document",
                "mediaType" => "audio/ogg",
                "url" => "https://remote.example/a.ogg"
              }
            ]
          })
      }

      assert handle(activity, context) == :ok

      status = Statuses.get_status_unchecked_by_uri("https://remote.example/statuses/1")

      assert Enum.map(Abuuba.Media.for_status(status), & &1.type) == [:video, :audio]
    end

    test "ignores an attachment with nowhere to fetch it from", context do
      activity = %{
        "type" => "Create",
        "actor" => @remote_actor,
        "object" =>
          note(%{
            "attachment" => [
              %{"type" => "Document", "mediaType" => "image/png"},
              %{"type" => "Link", "href" => "https://remote.example/elsewhere"}
            ]
          })
      }

      assert handle(activity, context) == :ok

      status = Statuses.get_status_unchecked_by_uri("https://remote.example/statuses/1")
      assert Abuuba.Media.for_status(status) == []
    end

    test "takes no more than this server allows on a post", context do
      too_many =
        for n <- 1..(Abuuba.Instance.max_media_attachments() + 3) do
          %{
            "type" => "Document",
            "mediaType" => "image/png",
            "url" => "https://remote.example/#{n}.png"
          }
        end

      activity = %{
        "type" => "Create",
        "actor" => @remote_actor,
        "object" => note(%{"attachment" => too_many})
      }

      assert handle(activity, context) == :ok

      status = Statuses.get_status_unchecked_by_uri("https://remote.example/statuses/1")

      # A sender listing forty pictures is a sender this server does not have
      # to believe.
      assert length(Abuuba.Media.for_status(status)) == Abuuba.Instance.max_media_attachments()
    end

    test "reads the alt text whichever field it was written in", context do
      assert handle(create_with(%{"summary" => "written as a summary"}), context) == :ok

      assert [%{description: "written as a summary"}] = attachments_of("1")
    end

    test "reads a url given as an object or a list", context do
      activity =
        create(%{
          "attachment" => [
            document(%{
              "url" => %{"type" => "Link", "href" => "https://remote.example/object.png"}
            }),
            document(%{"url" => [%{"href" => "https://remote.example/list.png"}]})
          ]
        })

      assert handle(activity, context) == :ok

      # All three spellings are legal and all three are sent. Reading only the
      # string dropped the picture with no trace.
      assert Enum.map(attachments_of("1"), & &1.remote_url) ==
               ["https://remote.example/object.png", "https://remote.example/list.png"]
    end

    test "keeps the sender's own thumbnail where they published one", context do
      icon = %{"type" => "Image", "url" => "https://remote.example/small.png"}

      assert handle(create_with(%{"icon" => icon}), context) == :ok

      # Without it the thumbnail is fetched from the full-size address, which
      # costs a reader the whole photograph to see it at four hundred pixels.
      assert [%{meta: %{"preview_remote_url" => "https://remote.example/small.png"}}] =
               attachments_of("1")
    end

    test "does not choke on a field longer than its column", context do
      # These are strings a stranger chose. Overflowing a column inside a
      # delivery job takes the job with it, and on an edit every retry of it.
      assert handle(create_with(%{"blurhash" => String.duplicate("z", 400)}), context) == :ok

      assert [%{blurhash: kept}] = attachments_of("1")
      assert String.length(kept) <= 255
    end

    test "calls a gif an image, because that is what it stores", context do
      assert handle(create_with(%{"mediaType" => "image/gif"}), context) == :ok

      # `gifv` means "a video to loop silently", which is what a transcoded GIF
      # becomes. This server keeps the GIF, and a client told gifv builds a
      # video player around a picture.
      assert [%{type: :image}] = attachments_of("1")
    end

    test "a redelivery changes nothing", context do
      activity = %{"type" => "Create", "actor" => @remote_actor, "object" => note()}

      assert handle(activity, context) == :ok
      assert handle(activity, context) == :ok

      assert Repo.aggregate(Statuses.not_deleted(), :count) == 1
    end

    test "a post attributed to another host is dropped, not retried", context do
      # The attribution rule will refuse it again in five minutes just as
      # firmly, so failing the job would only make the queue try forever.
      activity = %{
        "type" => "Create",
        "actor" => @remote_actor,
        "object" => note(%{"attributedTo" => "https://good.example/users/bob"})
      }

      assert handle(activity, context) == :ok
      assert Statuses.get_status_unchecked_by_uri("https://remote.example/statuses/1") == nil
    end
  end

  describe "mentions and hashtags" do
    test "come from the tag array, not from parsing the text", context do
      # The sender has already worked out who it addressed and under which
      # tags. Re-deriving that from HTML would disagree with them on exactly
      # the cases that matter.
      activity = %{
        "type" => "Create",
        "actor" => @remote_actor,
        "object" =>
          note(%{
            "content" => "hi @local #Caturday",
            "tag" => [
              %{"type" => "Mention", "href" => Actor.id(context.local), "name" => "@local"},
              %{"type" => "Hashtag", "name" => "#Caturday"}
            ]
          })
      }

      assert handle(activity, context) == :ok

      status = Statuses.get_status_unchecked_by_uri("https://remote.example/statuses/1")

      assert Repo.get_by(Abuuba.Statuses.Mention,
               status_id: status.id,
               account_id: context.local.id
             )

      tag = Repo.get_by(Abuuba.Statuses.Tag, name: "caturday")
      assert tag
      assert status.id in Enum.map(Statuses.tag_timeline(tag), & &1.id)
    end

    test "a mention of somebody we have never heard of is not a reason to fetch them", context do
      # Otherwise any post could make us resolve any actor, which is a fetch
      # amplifier pointed at whoever the sender names.
      activity = %{
        "type" => "Create",
        "actor" => @remote_actor,
        "object" =>
          note(%{
            "tag" => [%{"type" => "Mention", "href" => "https://elsewhere.example/users/nobody"}]
          })
      }

      assert handle(activity, context) == :ok
      assert Repo.aggregate(Abuuba.Statuses.Mention, :count) == 0
    end

    test "a tag array that is nonsense does not break the post", context do
      activity = %{
        "type" => "Create",
        "actor" => @remote_actor,
        "object" => note(%{"tag" => ["not a map", %{"type" => "Emoji"}, nil]})
      }

      assert handle(activity, context) == :ok
      assert Statuses.get_status_unchecked_by_uri("https://remote.example/statuses/1")
    end
  end

  describe "Announce" do
    setup context do
      original = status_fixture(%{account_id: context.local.id, uri: "#{URIs.base_url()}/s/1"})

      Map.put(context, :original, original)
    end

    test "records a boost", context do
      activity = %{
        "type" => "Announce",
        "actor" => @remote_actor,
        "object" => context.original.uri,
        "to" => [@public]
      }

      assert handle(activity, context) == :ok

      boost = Repo.get_by(Abuuba.Statuses.Status, reblog_of_id: context.original.id)
      assert boost.account_id == context.remote.id
    end

    test "a redelivery does not boost twice", context do
      activity = %{
        "type" => "Announce",
        "actor" => @remote_actor,
        "object" => context.original.uri,
        "to" => [@public]
      }

      handle(activity, context)
      assert handle(activity, context) == :ok

      assert Repo.aggregate(
               Ecto.Query.from(s in Abuuba.Statuses.Status, where: not is_nil(s.reblog_of_id)),
               :count
             ) == 1
    end

    test "takes its audience from the boost, not from the original", context do
      # Boosting to followers-only is a real thing people do, and taking the
      # original's visibility would leak it.
      activity = %{
        "type" => "Announce",
        "actor" => @remote_actor,
        "object" => context.original.uri,
        "to" => ["#{@remote_actor}/followers"]
      }

      handle(activity, context)

      boost = Repo.get_by(Abuuba.Statuses.Status, reblog_of_id: context.original.id)
      assert boost.visibility == :private
    end
  end

  describe "Delete" do
    test "removes a post its author sent it for", context do
      status =
        status_fixture(%{
          account_id: context.remote.id,
          uri: "https://remote.example/statuses/1",
          local: false
        })

      activity = %{"type" => "Delete", "actor" => @remote_actor, "object" => status.uri}

      assert handle(activity, context) == :ok
      assert Statuses.get_status(status.id, nil) == nil
      assert Inbox.tombstoned?(status.uri)
    end

    test "refuses to remove somebody else's post", context do
      # Without this check a Delete from any server would remove anybody's
      # post, which is a one-line denial of service against the network.
      status = status_fixture(%{account_id: context.local.id, uri: "#{URIs.base_url()}/s/1"})

      activity = %{"type" => "Delete", "actor" => @remote_actor, "object" => status.uri}

      assert handle(activity, context) == :ok
      assert Statuses.get_status(status.id, nil)
    end

    test "removes an account when the object is the actor itself", context do
      activity = %{"type" => "Delete", "actor" => @remote_actor, "object" => @remote_actor}

      assert handle(activity, context) == :ok
      assert Repo.get(Abuuba.Accounts.Account, context.remote.id) == nil
    end

    test "a delete for something we never had is not an error", context do
      activity = %{
        "type" => "Delete",
        "actor" => @remote_actor,
        "object" => "https://remote.example/statuses/never"
      }

      assert handle(activity, context) == :ok
    end
  end

  describe "Follow" do
    test "is accepted straight away for an ordinary account", context do
      activity = %{
        "id" => "https://remote.example/activities/f1",
        "type" => "Follow",
        "actor" => @remote_actor,
        "object" => Actor.id(context.local)
      }

      assert handle(activity, context) == :ok
      assert Relationships.following?(context.remote, context.local)
    end

    test "sends an Accept back to the server that asked", context do
      # Deliberately asserted against the delivery queue rather than against an
      # injected reply function. The handler took one for years and production
      # passed none, so the follow was recorded here and the asker was never
      # told -- with a green test the whole time saying an Accept was sent.
      activity = %{
        "id" => "https://remote.example/activities/f1",
        "type" => "Follow",
        "actor" => @remote_actor,
        "object" => Actor.id(context.local)
      }

      assert handle(activity, context) == :ok

      assert [%{"inbox" => inbox, "activity" => accept}] = queued_deliveries()
      assert inbox == context.remote.inbox_url
      assert accept["type"] == "Accept"
      assert accept["actor"] == Actor.id(context.local)
      assert accept["to"] == [@remote_actor]

      # The object is the document that arrived. A peer matches an answer
      # against what it sent, so naming our own row for the same follow leaves
      # it waiting for an answer it cannot recognise.
      assert accept["object"]["id"] == activity["id"]
      assert accept["object"]["type"] == "Follow"
    end

    test "becomes a pending request for an account that approves followers", context do
      locked =
        account_fixture(%{
          username: "locked",
          locked: true,
          uri: "#{URIs.base_url()}/users/locked"
        })

      activity = %{
        "id" => "https://remote.example/activities/f2",
        "type" => "Follow",
        "actor" => @remote_actor,
        "object" => locked.uri
      }

      assert handle(activity, context) == :ok
      refute Relationships.following?(context.remote, locked)
      assert Relationships.get_follow_request(context.remote, locked)

      # And nothing is sent yet: the answer is the account holder's to give.
      assert queued_deliveries() == []
    end

    test "is rejected out loud when blocked", context do
      # Silence looks like a server that is down, so the requester retries
      # forever. A Reject ends it.
      {:ok, _} = Relationships.block(context.local, context.remote)

      activity = %{
        "id" => "https://remote.example/activities/f3",
        "type" => "Follow",
        "actor" => @remote_actor,
        "object" => Actor.id(context.local)
      }

      handle(activity, context)

      # The block queued a delivery of its own, so the Reject is picked out
      # rather than assumed to be the only thing waiting.
      assert [reject] =
               queued_deliveries()
               |> Enum.map(& &1["activity"])
               |> Enum.filter(&(&1["type"] == "Reject"))

      assert reject["object"]["id"] == activity["id"]
      refute Relationships.following?(context.remote, context.local)
    end

    test "a follow aimed at nobody here is not work", context do
      activity = %{
        "type" => "Follow",
        "actor" => @remote_actor,
        "object" => "https://elsewhere.example/users/nobody"
      }

      assert handle(activity, context) == :ok
    end
  end

  describe "Accept and Reject" do
    setup context do
      {:ok, request} =
        Relationships.request_follow(context.local, context.remote, %{
          uri: "#{URIs.base_url()}/activities/f1"
        })

      Map.put(context, :request, request)
    end

    test "an Accept turns our request into a follow", context do
      activity = %{
        "type" => "Accept",
        "actor" => @remote_actor,
        "object" => %{"type" => "Follow", "actor" => Actor.id(context.local)}
      }

      assert handle(activity, context) == :ok
      assert Relationships.following?(context.local, context.remote)
    end

    test "an Accept naming only the Follow's id still completes it", context do
      # The request a peer answers is the one we made, and we do not store the
      # id of the Follow we sent: it is built from the row. A peer that echoes
      # the whole Follow object -- Mastodon does -- is matched by the actor
      # inside it, and one that echoes only the id -- GoToSocial does -- was
      # matched by nothing at all, so the follow stayed pending for ever.
      # No stored uri, which is what a request abuuba made looks like: the id of
      # the Follow it sent is built from the row rather than kept.
      {:ok, request} =
        context.request |> Ecto.Changeset.change(uri: nil) |> Abuuba.Repo.update()

      activity = %{
        "type" => "Accept",
        "actor" => @remote_actor,
        "object" => "#{Actor.id(context.local)}#follows/#{request.id}"
      }

      assert handle(activity, context) == :ok
      assert Relationships.following?(context.local, context.remote)
    end

    test "and one naming somebody else's request does nothing", context do
      # The id is ours to build, so a peer could name any of them. The actor in
      # the id has to be the account whose request it is.
      other = account_fixture(%{username: "other"})
      {:ok, request} = Relationships.request_follow(other, context.remote)

      activity = %{
        "type" => "Accept",
        "actor" => @remote_actor,
        "object" => "#{Actor.id(context.local)}#follows/#{request.id}"
      }

      assert handle(activity, context) == :ok
      refute Relationships.following?(other, context.remote)
      refute Relationships.following?(context.local, context.remote)
    end

    test "an Accept delivered twice is not an error", context do
      activity = %{
        "type" => "Accept",
        "actor" => @remote_actor,
        "object" => %{"type" => "Follow", "actor" => Actor.id(context.local)}
      }

      handle(activity, context)
      assert handle(activity, context) == :ok
    end

    test "a Reject removes both the request and any follow", context do
      # A Reject for an already-accepted follow is how a server says
      # "actually, no longer".
      activity = %{
        "type" => "Reject",
        "actor" => @remote_actor,
        "object" => %{"type" => "Follow", "actor" => Actor.id(context.local)}
      }

      assert handle(activity, context) == :ok
      assert Relationships.get_follow_request(context.local, context.remote) == nil
      refute Relationships.following?(context.local, context.remote)
    end
  end

  describe "Add and Remove on a featured collection" do
    # A pin arriving from somebody else's server. Covered end to end by the
    # interop suite, and by nothing that runs on every commit -- which for a
    # handler carrying two authorisation checks is the wrong way round.
    defp remote_note(context, id) do
      status_fixture(%{
        account_id: context.remote.id,
        local: false,
        uri: id,
        text: "theirs"
      })
    end

    defp add_activity(context, object_uri, target) do
      %{
        "type" => "Add",
        "actor" => @remote_actor,
        "object" => object_uri,
        "target" => target || "#{context.remote.uri}/collections/featured"
      }
    end

    test "pins a post its author put in their own collection", context do
      status = remote_note(context, "https://remote.example/statuses/pinned")

      assert handle(add_activity(context, status.uri, nil), context) == :ok
      assert Enum.map(Statuses.pinned(context.remote, nil), & &1.id) == [status.id]
    end

    test "and unpins it again", context do
      status = remote_note(context, "https://remote.example/statuses/pinned")

      handle(add_activity(context, status.uri, nil), context)

      remove = %{
        "type" => "Remove",
        "actor" => @remote_actor,
        "object" => status.uri,
        "target" => "#{context.remote.uri}/collections/featured"
      }

      assert handle(remove, context) == :ok
      assert Statuses.pinned(context.remote, nil) == []
    end

    test "but not into somebody else's collection", context do
      # The check the moduledoc is about: without it any server could pin
      # anything to anybody's profile. The target here is a local account's
      # featured collection, named by a remote actor.
      status = remote_note(context, "https://remote.example/statuses/pinned")
      theirs = Actor.id(context.local) <> "/collections/featured"

      assert handle(add_activity(context, status.uri, theirs), context) == :ok
      assert Statuses.pinned(context.local, nil) == []
      assert Statuses.pinned(context.remote, nil) == []
    end

    test "and not somebody else's post into their own", context do
      # The second check, and a different theft: the collection is theirs, the
      # post is not. Pinning it would put another account's words at the top of
      # their profile under their name.
      #
      # The post has to be one this server can find by uri, or the handler
      # never reaches the pin at all and takes the featured-tag path instead --
      # which is how the first version of this test passed with the check
      # removed.
      other =
        remote_account_fixture(%{
          username: "bob",
          domain: "other.example",
          uri: "https://other.example/users/bob"
        })

      theirs =
        status_fixture(%{
          account_id: other.id,
          local: false,
          uri: "https://other.example/statuses/1",
          text: "not theirs to pin"
        })

      assert handle(add_activity(context, theirs.uri, nil), context) == :ok
      assert Statuses.pinned(context.remote, nil) == []
    end
  end

  describe "Like" do
    test "records a favourite", context do
      status = status_fixture(%{account_id: context.local.id, uri: "#{URIs.base_url()}/s/1"})

      activity = %{"type" => "Like", "actor" => @remote_actor, "object" => status.uri}

      assert handle(activity, context) == :ok
      assert Repo.get_by(Abuuba.Statuses.Favourite, status_id: status.id)
    end

    test "a like for a post we do not hold is not a reason to go and get it", context do
      # Otherwise any server could make us fetch anything by pretending to
      # like it.
      activity = %{
        "type" => "Like",
        "actor" => @remote_actor,
        "object" => "https://elsewhere.example/statuses/1"
      }

      assert handle(activity, context) == :ok
    end

    test "a redelivery does not favourite twice", context do
      status = status_fixture(%{account_id: context.local.id, uri: "#{URIs.base_url()}/s/1"})
      activity = %{"type" => "Like", "actor" => @remote_actor, "object" => status.uri}

      handle(activity, context)
      assert handle(activity, context) == :ok
      assert Repo.aggregate(Abuuba.Statuses.Favourite, :count) == 1
    end
  end

  describe "Block" do
    test "is recorded and brings the follows down", context do
      {:ok, _} = Relationships.follow(context.local, context.remote)

      activity = %{
        "type" => "Block",
        "actor" => @remote_actor,
        "object" => Actor.id(context.local)
      }

      assert handle(activity, context) == :ok
      assert Relationships.blocking?(context.remote, context.local)
      refute Relationships.following?(context.local, context.remote)
    end
  end

  describe "Undo" do
    test "takes back a follow", context do
      {:ok, _} = Relationships.follow(context.remote, context.local)

      activity = %{
        "type" => "Undo",
        "actor" => @remote_actor,
        "object" => %{
          "type" => "Follow",
          "actor" => @remote_actor,
          "object" => Actor.id(context.local)
        }
      }

      assert handle(activity, context) == :ok
      refute Relationships.following?(context.remote, context.local)
    end

    test "takes back a like", context do
      status = status_fixture(%{account_id: context.local.id, uri: "#{URIs.base_url()}/s/1"})
      {:ok, _} = Statuses.favourite(context.remote, status)

      activity = %{
        "type" => "Undo",
        "actor" => @remote_actor,
        "object" => %{"type" => "Like", "actor" => @remote_actor, "object" => status.uri}
      }

      assert handle(activity, context) == :ok
      assert Repo.aggregate(Abuuba.Statuses.Favourite, :count) == 0
    end

    test "takes back a boost", context do
      original = status_fixture(%{account_id: context.local.id, uri: "#{URIs.base_url()}/s/1"})
      {:ok, boost} = Statuses.boost(context.remote, original)

      activity = %{
        "type" => "Undo",
        "actor" => @remote_actor,
        "object" => %{"type" => "Announce", "actor" => @remote_actor, "object" => original.uri}
      }

      assert handle(activity, context) == :ok
      assert Statuses.get_status(boost.id, nil) == nil
    end

    test "takes back a block", context do
      {:ok, _} = Relationships.block(context.remote, context.local)

      activity = %{
        "type" => "Undo",
        "actor" => @remote_actor,
        "object" => %{
          "type" => "Block",
          "actor" => @remote_actor,
          "object" => Actor.id(context.local)
        }
      }

      assert handle(activity, context) == :ok
      refute Relationships.blocking?(context.remote, context.local)
    end

    test "works out what is being undone from a bare URI", context do
      # Some servers send only the undone activity's id, so there is no type to
      # read. The URI is that activity's own id, so at most one thing matches.
      follow_uri = "https://remote.example/activities/f9"
      {:ok, _} = Relationships.follow(context.remote, context.local, %{uri: follow_uri})

      activity = %{"type" => "Undo", "actor" => @remote_actor, "object" => follow_uri}

      assert handle(activity, context) == :ok
      refute Relationships.following?(context.remote, context.local)
    end

    test "undoing something that was never done is not an error", context do
      activity = %{
        "type" => "Undo",
        "actor" => @remote_actor,
        "object" => %{
          "type" => "Like",
          "actor" => @remote_actor,
          "object" => "https://x.example/1"
        }
      }

      assert handle(activity, context) == :ok
    end
  end

  describe "Update" do
    test "refetches an actor rather than trusting what was pushed", context do
      # The pushed document is a claim; the actor's own endpoint is where the
      # claim gets checked, including the loopback check.
      me = self()

      activity = %{
        "type" => "Update",
        "actor" => @remote_actor,
        "object" => %{"id" => @remote_actor, "type" => "Person", "name" => "Whatever"}
      }

      handle(activity, context,
        refresh_actor: fn uri ->
          send(me, {:refetched, uri})
          {:ok, context.remote}
        end
      )

      assert_received {:refetched, @remote_actor}
    end

    test "updates a post we already hold", context do
      status =
        status_fixture(%{
          account_id: context.remote.id,
          uri: "https://remote.example/statuses/1",
          local: false,
          text: "before"
        })

      activity = %{
        "type" => "Update",
        "actor" => @remote_actor,
        "object" => note(%{"content" => "after"})
      }

      assert handle(activity, context) == :ok
      assert Repo.get!(Abuuba.Statuses.Status, status.id).text == "after"
    end

    test "refuses one sent by a server that does not host its author", context do
      status =
        status_fixture(%{
          account_id: context.remote.id,
          uri: "https://remote.example/statuses/1",
          local: false,
          text: "what they wrote"
        })

      # The signature binds the request to whoever sent it, and the sender is
      # checked against the activity's actor — but nothing tied either to the
      # post's author, so any server could rewrite anybody's post.
      activity = %{
        "type" => "Update",
        "actor" => "https://evil.example/users/mallory",
        "object" => note(%{"content" => "what somebody else put in their mouth"})
      }

      assert handle(activity, context) == :ok
      assert Repo.get!(Abuuba.Statuses.Status, status.id).text == "what they wrote"
    end

    test "refuses one that would strip a post's pictures", context do
      status =
        status_fixture(%{
          account_id: context.remote.id,
          uri: "https://remote.example/statuses/1",
          local: false
        })

      {:ok, status} =
        Abuuba.Media.replace_remote(status, [
          %{
            remote_url: "https://remote.example/one.png",
            file_content_type: "image/png",
            description: nil,
            blurhash: nil,
            meta: %{}
          }
        ])

      activity = %{
        "type" => "Update",
        "actor" => "https://evil.example/users/mallory",
        "object" => note(%{"attachment" => []})
      }

      assert handle(activity, context) == :ok
      assert length(Abuuba.Media.for_status(status)) == 1
    end

    test "an update for a post we never had is not a reason to fetch it", context do
      activity = %{
        "type" => "Update",
        "actor" => @remote_actor,
        "object" => note(%{"id" => "https://remote.example/statuses/unknown"})
      }

      assert handle(activity, context) == :ok

      assert Statuses.get_status_unchecked_by_uri("https://remote.example/statuses/unknown") ==
               nil
    end
  end

  describe "who may speak for a post" do
    test "a Create attributed to somebody the sender does not host is refused", context do
      # `attributedTo` says remote.example and the object id is on
      # remote.example, so the object is internally consistent — and it was
      # pushed by a server with no relationship to either.
      activity = %{
        "type" => "Create",
        "actor" => "https://evil.example/users/mallory",
        "object" => note(%{"content" => "words put in their mouth"})
      }

      assert handle(activity, context) == :ok
      assert Statuses.get_status_unchecked_by_uri("https://remote.example/statuses/1") == nil
    end

    test "the author's own server may still say all of it", context do
      # The positive control. Every refusal above passes just as happily
      # against a server that refuses everybody.
      create = %{"type" => "Create", "actor" => @remote_actor, "object" => note()}
      assert handle(create, context) == :ok

      status = Statuses.get_status_unchecked_by_uri("https://remote.example/statuses/1")
      assert status

      update = %{
        "type" => "Update",
        "actor" => @remote_actor,
        "object" => note(%{"content" => "second thoughts"})
      }

      assert handle(update, context) == :ok
      assert Repo.get!(Abuuba.Statuses.Status, status.id).text =~ "second thoughts"
    end
  end

  describe "activity types nothing handles" do
    test "are done rather than failed", context do
      # Returning an error would make the queue retry something no version of
      # this software is going to do.
      for type <- ~w(Arrive Travel Listen Question Offer) do
        assert handle(%{"type" => type, "actor" => @remote_actor}, context) == :ok
      end
    end

    test "so is something that is not an activity at all", context do
      assert handle(%{"no" => "type"}, context) == :ok
    end
  end

  describe "a Create carrying a vote" do
    setup context do
      status = status_fixture(%{account_id: context.local.id, text: "tea or coffee?"})

      {:ok, poll} =
        Abuuba.Statuses.create_poll(status, %{
          options: ["tea", "coffee"],
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      Map.merge(context, %{poll_status: status, poll: poll})
    end

    defp vote_activity(context, name, overrides \\ %{}) do
      %{
        "id" => "https://remote.example/activities/v#{System.unique_integer([:positive])}",
        "type" => "Create",
        "actor" => @remote_actor,
        "object" =>
          Map.merge(
            %{
              "id" => "https://remote.example/votes/#{System.unique_integer([:positive])}",
              "type" => "Note",
              "attributedTo" => @remote_actor,
              "name" => name,
              "inReplyTo" => Serializer.status_uri(context.poll_status)
            },
            overrides
          )
      }
    end

    test "is counted against the option it names", context do
      # A vote is a Note with a `name` and no content, and read as an ordinary
      # reply it becomes a post saying "tea" -- which is both a lost vote and a
      # reply nobody wrote.
      assert handle(vote_activity(context, "tea"), context) == :ok

      poll = Abuuba.Statuses.get_poll(context.poll_status)

      assert poll.tallies == [1, 0]
      assert poll.voters_count == 1
      refute Abuuba.Statuses.get_status_unchecked_by_uri("https://remote.example/votes/1")
    end

    test "a redelivery does not count twice", context do
      activity = vote_activity(context, "tea")

      handle(activity, context)
      handle(activity, context)

      assert Abuuba.Statuses.get_poll(context.poll_status).tallies == [1, 0]
    end

    test "an option nobody offered is not counted", context do
      assert handle(vote_activity(context, "milk"), context) == :ok

      assert Abuuba.Statuses.get_poll(context.poll_status).tallies == [0, 0]
    end

    test "a second choice is refused on a single-choice poll", context do
      handle(vote_activity(context, "tea"), context)
      handle(vote_activity(context, "coffee"), context)

      poll = Abuuba.Statuses.get_poll(context.poll_status)

      assert poll.tallies == [1, 0]
      assert poll.voters_count == 1
    end

    test "and allowed on a multiple-choice one, counting one voter", context do
      # A peer sends one activity per option, so the second must not read as
      # somebody voting twice -- and must not make them two voters either.
      {:ok, _} =
        context.poll
        |> Ecto.Changeset.change(multiple: true)
        |> Abuuba.Repo.update()

      handle(vote_activity(context, "tea"), context)
      handle(vote_activity(context, "coffee"), context)

      poll = Abuuba.Statuses.get_poll(context.poll_status)

      assert poll.tallies == [1, 1]
      assert poll.voters_count == 1
    end

    test "a vote on somebody else's poll is not ours to count", context do
      theirs =
        status_fixture(%{
          account_id: context.remote.id,
          uri: "https://remote.example/statuses/theirs",
          local: false
        })

      {:ok, _poll} =
        Abuuba.Statuses.create_poll(theirs, %{
          options: ["a", "b"],
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      activity =
        vote_activity(context, "a", %{"inReplyTo" => theirs.uri})

      assert handle(activity, context) == :ok
      assert Abuuba.Statuses.get_poll(theirs).tallies == [0, 0]
    end
  end
end
