defmodule Abuuba.Federation.ResolveStatusTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Conversations
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.ResolveStatus
  alias Abuuba.Notifications
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Status

  @uri "https://remote.example/statuses/1"
  @author "https://remote.example/users/alice"

  setup do
    account = remote_account_fixture(%{username: "alice", domain: "remote.example", uri: @author})

    %{account: account, resolve_actor: fn _uri -> {:ok, account} end}
  end

  defp note(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => @uri,
        "type" => "Note",
        "attributedTo" => @author,
        "content" => "<p>hello</p>",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      },
      overrides
    )
  end

  describe "a poll from another server" do
    test "arrives when the peer sends no votersCount", %{} = context do
      # `toot:votersCount` is Mastodon's extension rather than part of
      # ActivityStreams. Passing the key with a nil in it overrode the column's
      # own default and raised on the NOT NULL constraint, so a poll from a
      # server that does not send it could not federate to us at all.
      document = question(%{"id" => @uri <> "/novoters"}) |> Map.delete("votersCount")

      assert {:ok, status} = resolve(document, context, uri: @uri <> "/novoters")

      poll = Repo.get_by(Abuuba.Statuses.Poll, status_id: status.id)

      assert poll.options == ["tea", "coffee"]
      assert poll.voters_count == 0
    end

    test "and one with nothing to vote for is refused", %{} = context do
      # The API refuses this cleanly; the federation path stored a poll with no
      # options, because `validate_length/3` reads the change and `cast/3`
      # records none for a value equal to the field's default.
      document = question(%{"oneOf" => [], "id" => @uri <> "/empty"})

      assert {:ok, status} = resolve(document, context, uri: @uri <> "/empty")

      refute Repo.get_by(Abuuba.Statuses.Poll, status_id: status.id)
    end

    test "and an ordinary one still arrives", %{} = context do
      # The control: both assertions above are about something not happening.
      assert {:ok, status} =
               resolve(question(%{"id" => @uri <> "/plain"}), context, uri: @uri <> "/plain")

      poll = Repo.get_by(Abuuba.Statuses.Poll, status_id: status.id)

      assert poll.options == ["tea", "coffee"]
      assert poll.voters_count == 8
    end
  end

  defp question(overrides \\ %{}) do
    note(
      Map.merge(
        %{
          "type" => "Question",
          "content" => "<p>tea or coffee?</p>",
          "endTime" => "2030-01-01T12:00:00Z",
          "votersCount" => 8,
          "oneOf" => [
            %{
              "type" => "Note",
              "name" => "tea",
              "replies" => %{"type" => "Collection", "totalItems" => 3}
            },
            %{
              "type" => "Note",
              "name" => "coffee",
              "replies" => %{"type" => "Collection", "totalItems" => 5}
            }
          ]
        },
        overrides
      )
    )
  end

  defp resolve(document, context, opts \\ []) do
    ResolveStatus.resolve(
      Keyword.get(opts, :uri, @uri),
      Keyword.merge(
        [fetch: fn _uri -> {:ok, document} end, resolve_actor: context.resolve_actor],
        opts
      )
    )
  end

  describe "the conversation a post arrives in" do
    @thread "https://remote.example/contexts/9"

    test "is taken from what the sender called it", %{resolve_actor: _} = context do
      {:ok, status} = resolve(note(%{"conversation" => @thread}), context)

      assert Abuuba.Repo.get(Abuuba.Statuses.Conversation, status.conversation_id).uri == @thread
    end

    test "holds a reply and its parent together whichever arrives first", %{} = context do
      # The case this exists for. Delivery is unordered, so the reply routinely
      # turns up first and `inReplyTo` names a post this server has never seen.
      # Without a name for the thread the two get separate conversations and
      # never rejoin, so the thread reads as two and muting it silences one.
      reply_uri = "https://remote.example/statuses/2"

      {:ok, reply} =
        resolve(
          note(%{
            "id" => reply_uri,
            "inReplyTo" => @uri,
            "conversation" => @thread,
            "content" => "<p>the reply, arriving first</p>"
          }),
          context,
          uri: reply_uri
        )

      {:ok, parent} = resolve(note(%{"conversation" => @thread}), context)

      assert reply.conversation_id == parent.conversation_id
    end

    test "and two threads from the same server stay apart", %{} = context do
      # The positive control: if every remote post landed in one conversation,
      # the assertion above would pass and mean nothing.
      other_uri = "https://remote.example/statuses/3"

      {:ok, one} = resolve(note(%{"conversation" => @thread}), context)

      {:ok, other} =
        resolve(
          note(%{"id" => other_uri, "conversation" => "https://remote.example/contexts/10"}),
          context,
          uri: other_uri
        )

      refute one.conversation_id == other.conversation_id
    end

    test "a post that names none still gets one", %{} = context do
      {:ok, status} = resolve(note(), context)

      assert status.conversation_id
    end
  end

  describe "the attribution rule" do
    test "accepts an object attributed to somebody on its own host" do
      assert ResolveStatus.trustworthy_attribution?(
               "https://a.example/statuses/1",
               "https://a.example/users/alice"
             )
    end

    test "refuses an object claiming somebody on another host wrote it" do
      # This is the whole attack: evil.example publishes an object attributed
      # to alice@good.example and every server that believes it files a post
      # under her name that she never wrote.
      refute ResolveStatus.trustworthy_attribution?(
               "https://evil.example/statuses/1",
               "https://good.example/users/alice"
             )
    end

    test "compares hosts case-insensitively, since hostnames have no case" do
      assert ResolveStatus.trustworthy_attribution?(
               "https://A.example/statuses/1",
               "https://a.EXAMPLE/users/alice"
             )
    end

    test "is not fooled by a host that merely starts the same" do
      refute ResolveStatus.trustworthy_attribution?(
               "https://a.example.evil.example/statuses/1",
               "https://a.example/users/alice"
             )
    end

    test "refuses when either side is missing or nonsense" do
      refute ResolveStatus.trustworthy_attribution?(nil, "https://a.example/users/alice")
      refute ResolveStatus.trustworthy_attribution?("https://a.example/s/1", nil)
      refute ResolveStatus.trustworthy_attribution?("not a uri", "also not")
      refute ResolveStatus.trustworthy_attribution?("https://a.example/s/1", %{})
      refute ResolveStatus.trustworthy_attribution?("https://a.example/s/1", [])
    end

    test "reads attributedTo in every shape peers send it" do
      assert ResolveStatus.attribution_uri("https://a.example/u/1") == "https://a.example/u/1"

      assert ResolveStatus.attribution_uri(%{"id" => "https://a.example/u/1"}) ==
               "https://a.example/u/1"

      assert ResolveStatus.attribution_uri([%{"id" => "https://a.example/u/1"}, "other"]) ==
               "https://a.example/u/1"

      assert ResolveStatus.attribution_uri(nil) == nil
    end
  end

  describe "resolving a post" do
    test "stores it", context do
      assert {:ok, %Status{} = status} = resolve(note(), context)

      assert status.uri == @uri
      assert status.text == "<p>hello</p>"
      assert status.visibility == :public
      refute status.local
    end

    test "refuses one attributed to another host", context do
      document = note(%{"attributedTo" => "https://good.example/users/alice"})

      assert resolve(document, context) == {:error, :untrustworthy_attribution}
      assert Statuses.get_status_unchecked_by_uri(@uri) == nil
    end

    test "accepts a bare Note or one wrapped in a Create", context do
      wrapped = %{"type" => "Create", "id" => @uri <> "/activity", "object" => note()}

      assert {:ok, status} = resolve(wrapped, context)
      assert status.uri == @uri
    end

    test "refuses a wrapper whose object is only a reference", context do
      # A URI is not a document, and guessing at fetching it is the caller's
      # decision rather than something to do quietly here.
      wrapped = %{"type" => "Create", "object" => "https://remote.example/statuses/1"}

      assert resolve(wrapped, context) == {:error, :malformed_object}
    end

    test "refuses an object with no id", context do
      assert resolve(note() |> Map.delete("id"), context) == {:error, :object_without_id}
    end

    test "refuses a type it does not handle", context do
      assert resolve(note(%{"type" => "Person"}), context) ==
               {:error, :unsupported_object_type}
    end

    test "does not fetch again for a status it already holds", context do
      {:ok, first} = resolve(note(), context)

      {:ok, again} =
        ResolveStatus.resolve(@uri,
          fetch: fn _ -> flunk("should not have re-fetched") end,
          resolve_actor: context.resolve_actor
        )

      assert again.id == first.id
    end
  end

  describe "the refetch dance" do
    test "fetches again by the id the document names", context do
      canonical = "https://remote.example/statuses/canonical"

      fetch = fn url ->
        if url == canonical do
          {:ok, note(%{"id" => canonical})}
        else
          {:ok, note(%{"id" => canonical})}
        end
      end

      assert {:ok, status} =
               resolve(nil, context, fetch: fetch, uri: "https://remote.example/statuses/short")

      assert status.uri == canonical
    end

    test "refuses a server that will not agree with itself", context do
      # Answering for its own stated id with yet another id is a server playing
      # games, not a redirect.
      fetch = fn _url ->
        {:ok, note(%{"id" => "https://remote.example/statuses/#{:rand.uniform(9999)}"})}
      end

      assert {:error, :id_mismatch} =
               resolve(nil, context, fetch: fetch, uri: "https://remote.example/statuses/x")
    end

    test "does not mind a trailing slash", context do
      fetch = fn _url -> {:ok, note(%{"id" => @uri <> "/"})} end

      assert {:ok, _status} = resolve(nil, context, fetch: fetch)
    end
  end

  describe "visibility from the audience" do
    test "public, unlisted, followers-only and direct", context do
      public = "https://www.w3.org/ns/activitystreams#Public"
      followers = @author <> "/followers"

      cases = [
        {%{"to" => [public]}, :public},
        {%{"to" => [], "cc" => [public]}, :unlisted},
        {%{"to" => [followers]}, :private},
        {%{"to" => ["https://remote.example/users/bob"]}, :direct}
      ]

      for {{audience, expected}, index} <- Enum.with_index(cases) do
        uri = "#{@uri}/#{index}"
        document = note(Map.merge(%{"id" => uri}, audience))

        {:ok, status} = resolve(document, context, uri: uri)

        assert status.visibility == expected
      end
    end
  end

  describe "things that are not posts" do
    test "an article is kept as a link rather than as invented body text", context do
      # Dropping it would leave a reply pointing at nothing; inventing text for
      # it would put words in somebody's mouth.
      document =
        note(%{
          "type" => "Article",
          "url" => "https://remote.example/blog/hello",
          "content" => "a whole blog post"
        })

      {:ok, status} = resolve(document, context)

      assert status.text == "https://remote.example/blog/hello"
    end

    test "every link-only type is accepted", context do
      for {type, index} <- Enum.with_index(~w(Article Page Image Audio Video Event Document)) do
        uri = "#{@uri}/type/#{index}"

        assert {:ok, _status} =
                 resolve(note(%{"id" => uri, "type" => type}), context, uri: uri)
      end
    end
  end

  describe "a status the peer no longer has" do
    test "is removed here when a fetch finds it gone", context do
      # Their 404 is the only notice we are going to get.
      {:ok, status} = resolve(note(), context)

      # A fresh URI so resolve/2 actually fetches rather than answering from
      # what we already hold.
      gone_uri = "#{@uri}/gone"
      {:ok, gone} = resolve(note(%{"id" => gone_uri}), context, uri: gone_uri)

      # refresh/2 rather than resolve/2: only a request that actually goes out
      # can find out the post is gone.
      assert ResolveStatus.refresh(gone_uri,
               fetch: fn _ -> {:error, :not_found} end,
               resolve_actor: context.resolve_actor
             ) == {:error, :not_found}

      assert Statuses.get_status(gone.id, nil) == nil
      assert Statuses.get_status(status.id, nil), "only the one that went away"
    end

    test "forgetting one we never had is not an error" do
      assert ResolveStatus.forget("https://remote.example/statuses/never") == :ok
    end
  end

  describe "threads" do
    test "resolves what a reply replies to", context do
      parent_uri = "#{@uri}/parent"

      documents = %{
        @uri => note(%{"inReplyTo" => parent_uri}),
        parent_uri => note(%{"id" => parent_uri})
      }

      fetch = fn url -> {:ok, Map.fetch!(documents, url)} end

      assert {:ok, reply} =
               ResolveStatus.resolve_thread(@uri,
                 fetch: fetch,
                 resolve_actor: context.resolve_actor
               )

      parent = Statuses.get_status_unchecked_by_uri(parent_uri)

      assert parent
      assert reply.in_reply_to_id == parent.id
    end

    test "stops walking a chain deeper than the limit, but still returns the post", context do
      # The chain is attacker-controlled: a thread a thousand deep is a
      # thousand requests we make because somebody asked. Truncating the
      # ancestry is right; refusing to show the post somebody asked for
      # because its great-great-grandparent was unreachable is not.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fetch = fn url ->
        Agent.update(counter, &(&1 + 1))
        {:ok, note(%{"id" => url, "inReplyTo" => url <> "/up"})}
      end

      assert {:ok, status} =
               ResolveStatus.resolve_thread(@uri,
                 fetch: fetch,
                 resolve_actor: context.resolve_actor,
                 max_depth: 3
               )

      assert status.uri == @uri
      assert Agent.get(counter, & &1) <= 3, "the walk kept going past its limit"
    end

    test "stops when the discovery budget runs out", context do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fetch = fn url ->
        Agent.update(counter, &(&1 + 1))
        {:ok, note(%{"id" => url, "inReplyTo" => url <> "/up"})}
      end

      assert {:ok, _status} =
               ResolveStatus.resolve_thread(@uri,
                 fetch: fetch,
                 resolve_actor: context.resolve_actor,
                 max_discoveries: 2
               )

      assert Agent.get(counter, & &1) <= 2
    end

    test "stops walking at a status it already holds", context do
      parent_uri = "#{@uri}/parent"
      {:ok, parent} = resolve(note(%{"id" => parent_uri}), context, uri: parent_uri)

      fetch = fn
        @uri -> {:ok, note(%{"inReplyTo" => parent_uri})}
        _other -> flunk("should not have fetched a status we already hold")
      end

      assert {:ok, reply} =
               ResolveStatus.resolve_thread(@uri,
                 fetch: fetch,
                 resolve_actor: context.resolve_actor
               )

      assert reply.in_reply_to_id == parent.id
    end
  end

  describe "a Question" do
    test "arrives as a poll rather than as a post with the options missing", context do
      # A Question read as a Note keeps the text and loses everything that
      # makes it a poll, which is how it looks to a reader: a post asking a
      # question with no way to answer it.
      assert {:ok, status} = resolve(question(), context)

      poll = Statuses.get_poll(status)

      assert poll.options == ["tea", "coffee"]
      assert poll.tallies == [3, 5]
      assert poll.voters_count == 8

      assert DateTime.to_iso8601(DateTime.truncate(poll.expires_at, :second)) ==
               "2030-01-01T12:00:00Z"

      refute poll.multiple
    end

    test "with anyOf is a multiple-choice poll", context do
      document =
        question(%{
          "oneOf" => nil,
          "anyOf" => [
            %{"type" => "Note", "name" => "a"},
            %{"type" => "Note", "name" => "b"}
          ]
        })

      assert {:ok, status} = resolve(document, context)

      poll = Statuses.get_poll(status)

      assert poll.multiple
      assert poll.options == ["a", "b"]
    end

    test "and its counts are updated when it is fetched again", context do
      # The counts are the reason to refetch a poll at all: a poll whose
      # tallies never move is one that federated once and then went stale.
      assert {:ok, _status} = resolve(question(), context)

      moved =
        question(%{
          "votersCount" => 20,
          "oneOf" => [
            %{"type" => "Note", "name" => "tea", "replies" => %{"totalItems" => 11}},
            %{"type" => "Note", "name" => "coffee", "replies" => %{"totalItems" => 9}}
          ]
        })

      assert {:ok, status} =
               ResolveStatus.refresh(@uri,
                 fetch: fn _uri -> {:ok, moved} end,
                 resolve_actor: context.resolve_actor
               )

      poll = Statuses.get_poll(status)

      assert poll.tallies == [11, 9]
      assert poll.voters_count == 20
    end

    test "a Note that follows a Question does not leave a poll behind", context do
      # An edit that removes the poll has to remove it here too, or the post
      # keeps offering a vote its author withdrew.
      assert {:ok, _status} = resolve(question(), context)

      assert {:ok, status} =
               ResolveStatus.refresh(@uri,
                 fetch: fn _uri -> {:ok, note()} end,
                 resolve_actor: context.resolve_actor
               )

      assert Statuses.get_poll(status) == nil
    end
  end

  describe "a mention from another server" do
    test "tells the person who was mentioned", context do
      # The one activity that reaches somebody who follows nobody and is
      # followed by nobody, so it is the only way two strangers ever meet.
      # The mention row was being recorded and nobody was being told: the
      # local composer announced its own mentions and the inbound path did
      # not, so being mentioned from another server was silent.
      local = account_fixture(%{username: "mentioned"})

      document =
        note(%{
          "content" => "<p>hello @mentioned</p>",
          "tag" => [
            %{
              "type" => "Mention",
              "href" => Actor.id(local),
              "name" => "@mentioned@abuuba.test"
            }
          ]
        })

      assert {:ok, status} = resolve(document, context)

      assert [notification] = Notifications.list(local, %{})
      assert notification.type == "mention"
      assert notification.status_id == status.id
      assert notification.from_account_id == context.account.id
    end

    test "and a redelivery does not tell them twice", context do
      local = account_fixture(%{username: "mentioned2"})

      document =
        note(%{
          "tag" => [%{"type" => "Mention", "href" => Actor.id(local)}]
        })

      assert {:ok, _status} = resolve(document, context)

      assert {:ok, _status} =
               ResolveStatus.refresh(@uri,
                 fetch: fn _uri -> {:ok, document} end,
                 resolve_actor: context.resolve_actor
               )

      assert length(Notifications.list(local, %{})) == 1
    end

    test "a mention of somebody on a third server tells nobody here", context do
      # Not ours to announce, and not ours to invent an account for.
      document =
        note(%{
          "tag" => [
            %{"type" => "Mention", "href" => "https://elsewhere.example/users/carol"}
          ]
        })

      assert {:ok, _status} = resolve(document, context)
    end
  end

  describe "a direct message from another server" do
    test "reaches the conversations of the person it names", context do
      # The conversation is delivered when the post is created, and a post
      # arriving from elsewhere records its mentions afterwards -- so at the
      # moment the conversation was built there was nobody in it but the
      # sender, and the message landed in nobody's inbox. It arrived, it was
      # stored, it was addressed correctly, and the person it was written to
      # had no way to see it.
      local = account_fixture(%{username: "recipient"})

      document =
        note(%{
          "to" => [Actor.id(local)],
          "cc" => [],
          "content" => "<p>for you alone</p>",
          "tag" => [%{"type" => "Mention", "href" => Actor.id(local)}]
        })

      assert {:ok, status} = resolve(document, context)
      assert status.visibility == :direct

      assert [conversation] = Conversations.list(local, %{})
      assert conversation.last_status_id == status.id
      assert context.account.id in conversation.participant_account_ids
    end

    test "and a public post does not become a conversation", context do
      # The control: if every post made one, the check above would pass on a
      # server that had understood nothing about who the message was for.
      local = account_fixture(%{username: "bystander"})

      document = note(%{"tag" => [%{"type" => "Mention", "href" => Actor.id(local)}]})

      assert {:ok, _status} = resolve(document, context)
      assert Conversations.list(local, %{}) == []
    end
  end
end
