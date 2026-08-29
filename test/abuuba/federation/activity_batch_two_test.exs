defmodule Abuuba.Federation.ActivityBatchTwoTest do
  use Abuuba.DataCase, async: true

  import Ecto.Query, only: [from: 1, from: 2]
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Federation.Activity.Flag
  alias Abuuba.Federation.Activity.Move
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Handlers
  alias Abuuba.Federation.Quotes
  alias Abuuba.Federation.URIs
  alias Abuuba.Relationships

  @remote_actor "https://remote.example/users/alice"

  setup do
    remote =
      remote_account_fixture(%{username: "alice", domain: "remote.example", uri: @remote_actor})

    local = account_fixture(%{username: "local"})

    %{remote: remote, local: local, opts: [resolve_actor: fn _uri -> {:ok, remote} end]}
  end

  defp handle(activity, context, extra \\ []) do
    Handlers.handle(activity, Keyword.merge(context.opts, extra))
  end

  defp queued_deliveries do
    Oban.Job
    |> Repo.all()
    |> Enum.filter(&(&1.worker == "Abuuba.Federation.DeliveryWorker"))
    |> Enum.map(& &1.args["activity"])
  end

  describe "Flag" do
    test "records a report for a moderator to read", context do
      # Somebody's opinion arriving from a server whose moderation standards
      # are their own, so it queues rather than acting.
      status = status_fixture(%{account_id: context.local.id, uri: "#{URIs.base_url()}/s/1"})

      activity = %{
        "id" => "https://remote.example/reports/1",
        "type" => "Flag",
        "actor" => @remote_actor,
        "object" => [Actor.id(context.local), status.uri],
        "content" => "spam"
      }

      assert handle(activity, context) == :ok

      report =
        Repo.one(
          from r in "reports",
            select: %{
              target_account_id: r.target_account_id,
              comment: r.comment,
              status_ids: r.status_ids,
              action_taken_at: r.action_taken_at
            }
        )

      assert report.target_account_id == context.local.id
      assert report.comment == "spam"
      assert report.status_ids == [status.id]
      assert report.action_taken_at == nil, "nothing happens automatically"
    end

    test "truncates a comment rather than storing a novel", context do
      activity = %{
        "id" => "https://remote.example/reports/2",
        "type" => "Flag",
        "actor" => @remote_actor,
        "object" => [Actor.id(context.local)],
        "content" => String.duplicate("a", 10_000)
      }

      handle(activity, context)

      [comment] = Repo.all(from r in "reports", select: r.comment)
      assert String.length(comment) == Flag.max_comment()
    end

    test "a redelivery does not report twice", context do
      activity = %{
        "id" => "https://remote.example/reports/3",
        "type" => "Flag",
        "actor" => @remote_actor,
        "object" => [Actor.id(context.local)]
      }

      handle(activity, context)
      assert handle(activity, context) == :ok
      assert Repo.aggregate(from(r in "reports"), :count) == 1
    end

    test "a report about nobody here is not work", context do
      activity = %{
        "type" => "Flag",
        "actor" => @remote_actor,
        "object" => ["https://elsewhere.example/users/x"]
      }

      assert handle(activity, context) == :ok
      assert Repo.aggregate(from(r in "reports"), :count) == 0
    end
  end

  describe "Add and Remove on the featured collection" do
    setup context do
      status =
        status_fixture(%{
          account_id: context.remote.id,
          uri: "https://remote.example/statuses/1",
          local: false
        })

      Map.put(context, :status, status)
    end

    test "pins a post to its own author's profile", context do
      activity = %{
        "type" => "Add",
        "actor" => @remote_actor,
        "object" => context.status.uri,
        "target" => "#{@remote_actor}/collections/featured"
      }

      assert handle(activity, context) == :ok
      assert Repo.aggregate(from(p in "status_pins"), :count) == 1
    end

    test "refuses to pin to somebody else's collection", context do
      # Otherwise any server could pin anything to anybody's profile.
      activity = %{
        "type" => "Add",
        "actor" => @remote_actor,
        "object" => context.status.uri,
        "target" => "#{Actor.id(context.local)}/collections/featured"
      }

      assert handle(activity, context) == :ok
      assert Repo.aggregate(from(p in "status_pins"), :count) == 0
    end

    test "refuses to pin somebody else's post", context do
      # Letting this through would put words on a profile its owner did not
      # choose.
      other = status_fixture(%{account_id: context.local.id, uri: "#{URIs.base_url()}/s/9"})

      activity = %{
        "type" => "Add",
        "actor" => @remote_actor,
        "object" => other.uri,
        "target" => "#{@remote_actor}/collections/featured"
      }

      assert handle(activity, context) == :ok
      assert Repo.aggregate(from(p in "status_pins"), :count) == 0
    end

    test "unpins", context do
      add = %{
        "type" => "Add",
        "actor" => @remote_actor,
        "object" => context.status.uri,
        "target" => "#{@remote_actor}/collections/featured"
      }

      handle(add, context)
      handle(%{add | "type" => "Remove"}, context)

      assert Repo.aggregate(from(p in "status_pins"), :count) == 0
    end

    test "features a hashtag", context do
      activity = %{
        "type" => "Add",
        "actor" => @remote_actor,
        "object" => %{"type" => "Hashtag", "name" => "#Caturday"},
        "target" => "#{@remote_actor}/collections/tags"
      }

      assert handle(activity, context) == :ok
      assert Repo.aggregate(from(f in "featured_tags"), :count) == 1
    end
  end

  describe "Move" do
    setup context do
      target =
        remote_account_fixture(%{
          username: "alice",
          domain: "new.example",
          uri: "https://new.example/users/alice",
          also_known_as: [@remote_actor]
        })

      {:ok, follower} = {:ok, account_fixture(%{username: "follower"})}
      {:ok, _} = Relationships.follow(follower, context.remote)

      # Re-read rather than closing over the structs from setup, or a test that
      # changes a row would still be handed the stale copy.
      context
      |> Map.put(:target, target)
      |> Map.put(:follower, follower)
      |> Map.put(:opts,
        resolve_actor: fn uri -> {:ok, Repo.get_by!(Abuuba.Accounts.Account, uri: uri)} end
      )
    end

    test "moves local followers when the target claims the origin back", context do
      activity = %{
        "type" => "Move",
        "actor" => @remote_actor,
        "object" => @remote_actor,
        "target" => context.target.uri
      }

      assert handle(activity, context) == :ok

      assert Relationships.following?(context.follower, context.target)
      refute Relationships.following?(context.follower, context.remote)
      assert Accounts.get_account(context.remote.id).moved_to_account_id == context.target.id
    end

    test "refuses when the target does not claim the origin", context do
      # Without the backlink, anybody could publish a Move naming any account
      # as the origin and inherit its followers.
      Repo.update!(Ecto.Changeset.change(context.target, also_known_as: []))

      activity = %{
        "type" => "Move",
        "actor" => @remote_actor,
        "object" => @remote_actor,
        "target" => context.target.uri
      }

      assert handle(activity, context) == :ok
      assert Relationships.following?(context.follower, context.remote)
      refute Relationships.following?(context.follower, context.target)
    end

    test "refuses a second move inside the cooldown", context do
      # A chain of moves walks a follower list across the network faster than
      # a moderator can follow it.
      Repo.update!(Ecto.Changeset.change(context.remote, moved_at: DateTime.utc_now()))

      activity = %{
        "type" => "Move",
        "actor" => @remote_actor,
        "object" => @remote_actor,
        "target" => context.target.uri
      }

      assert handle(activity, context) == :ok
      refute Relationships.following?(context.follower, context.target)
    end

    test "allows a move once the cooldown has passed", context do
      Repo.update!(
        Ecto.Changeset.change(context.remote,
          moved_at: DateTime.add(DateTime.utc_now(), -Move.cooldown_days() - 1, :day)
        )
      )

      activity = %{
        "type" => "Move",
        "actor" => @remote_actor,
        "object" => @remote_actor,
        "target" => context.target.uri
      }

      assert handle(activity, context) == :ok
      assert Relationships.following?(context.follower, context.target)
    end

    test "leaves remote followers to their own servers", context do
      # Re-following on their behalf would be doing to them exactly what this
      # handler exists to prevent.
      remote_follower =
        remote_account_fixture(%{
          username: "bob",
          domain: "third.example",
          uri: "https://third.example/users/bob"
        })

      {:ok, _} = Relationships.follow(remote_follower, context.remote)

      activity = %{
        "type" => "Move",
        "actor" => @remote_actor,
        "object" => @remote_actor,
        "target" => context.target.uri
      }

      handle(activity, context)

      assert Relationships.following?(remote_follower, context.remote)
      refute Relationships.following?(remote_follower, context.target)
    end
  end

  describe "quote posts" do
    setup context do
      quoted =
        status_fixture(%{
          account_id: context.remote.id,
          uri: "https://remote.example/statuses/quoted",
          local: false
        })

      quoting =
        status_fixture(%{
          account_id: context.local.id,
          uri: "#{URIs.base_url()}/statuses/quoting"
        })

      context |> Map.put(:quoted, quoted) |> Map.put(:quoting, quoting)
    end

    defp authorization(quoting, quoted, overrides \\ %{}) do
      Map.merge(
        %{
          "id" => "https://remote.example/approvals/1",
          "type" => "QuoteAuthorization",
          "interactingObject" => quoting.uri,
          "interactionTarget" => quoted.uri
        },
        overrides
      )
    end

    test "an approval from the quoted author's host is accepted", context do
      Quotes.record(context.quoting, context.quoted.uri, "https://remote.example/approvals/1")

      assert {:ok, :accepted} =
               Quotes.verify(context.quoting,
                 fetch: fn _ -> {:ok, authorization(context.quoting, context.quoted)} end
               )

      assert Quotes.state(context.quoting.id) == "accepted"
    end

    test "an approval hosted somewhere else is not an approval", context do
      # One hosted anywhere but the quoted author's own server is one the
      # author never gave.
      Quotes.record(context.quoting, context.quoted.uri, "https://evil.example/approvals/1")

      assert {:ok, :pending} =
               Quotes.verify(context.quoting,
                 fetch: fn _ ->
                   {:ok,
                    authorization(context.quoting, context.quoted, %{
                      "id" => "https://evil.example/approvals/1"
                    })}
                 end
               )
    end

    test "an approval for a different quote cannot be replayed", context do
      Quotes.record(context.quoting, context.quoted.uri, "https://remote.example/approvals/1")

      assert {:ok, :pending} =
               Quotes.verify(context.quoting,
                 fetch: fn _ ->
                   {:ok,
                    authorization(context.quoting, context.quoted, %{
                      "interactingObject" => "https://elsewhere.example/statuses/other"
                    })}
                 end
               )
    end

    test "an approval to quote one post is not an approval to quote another", context do
      Quotes.record(context.quoting, context.quoted.uri, "https://remote.example/approvals/1")

      assert {:ok, :pending} =
               Quotes.verify(context.quoting,
                 fetch: fn _ ->
                   {:ok,
                    authorization(context.quoting, context.quoted, %{
                      "interactionTarget" => "https://remote.example/statuses/something-else"
                    })}
                 end
               )
    end

    test "a quote with no approval at all stays pending, and is kept", context do
      # Dropping it would lose the post. A client can render it as a plain
      # link; what it must not do is present it as endorsed.
      Quotes.record(context.quoting, context.quoted.uri, nil)

      assert {:ok, :pending} = Quotes.verify(context.quoting)
      assert Quotes.state(context.quoting.id) == "pending"
    end

    test "reads the legacy spellings servers used before the spec", _context do
      assert Quotes.quoted_uri(%{"quote" => "https://a.example/1"}) == "https://a.example/1"
      assert Quotes.quoted_uri(%{"quoteUri" => "https://a.example/2"}) == "https://a.example/2"

      assert Quotes.quoted_uri(%{"_misskey_quote" => "https://a.example/3"}) ==
               "https://a.example/3"

      assert Quotes.quoted_uri(%{}) == nil
    end

    # Asserted against the delivery queue rather than an injected reply
    # function, which is what production takes. The handler used to hand its
    # decision to an `opts[:reply]` only tests ever passed, so a request was
    # weighed up and then answered with silence -- and the peer, having asked
    # permission, never got one.
    test "a quote request for a public post is accepted, and says where the approval is",
         context do
      theirs =
        status_fixture(%{
          account_id: context.remote.id,
          uri: "https://remote.example/statuses/new"
        })

      activity = %{
        "id" => "https://remote.example/activities/qr1",
        "type" => "QuoteRequest",
        "actor" => @remote_actor,
        "object" => context.quoting.uri,
        "instrument" => theirs.uri
      }

      handle(activity, context)

      assert [accept] = queued_deliveries()
      assert accept["type"] == "Accept"
      assert accept["actor"] == Actor.id(context.local)
      assert accept["object"]["id"] == activity["id"]

      # The whole point of the answer: the document that proves the quote was
      # allowed, which the quoting server embeds and everybody else checks.
      assert accept["result"] == Quotes.authorization_uri(theirs, context.quoting)
    end

    test "and the quote is recorded here as approved, so the approval can be served",
         context do
      # The endpoint that serves a QuoteAuthorization answers from the quote
      # row. Without it the Accept names a URL that answers 404, which is worse
      # than refusing outright.
      theirs =
        status_fixture(%{
          account_id: context.remote.id,
          uri: "https://remote.example/statuses/new"
        })

      handle(
        %{
          "id" => "https://remote.example/activities/qr2",
          "type" => "QuoteRequest",
          "actor" => @remote_actor,
          "object" => context.quoting.uri,
          "instrument" => theirs.uri
        },
        context
      )

      assert Quotes.state(theirs.id) == "accepted"
      assert Quotes.quoted_status_id(theirs) == context.quoting.id
    end

    test "a quote request for a non-public post is refused", context do
      # Somebody who posted to their followers chose that audience, and a quote
      # is how a post leaves it.
      private =
        status_fixture(%{
          account_id: context.local.id,
          uri: "#{URIs.base_url()}/statuses/private",
          visibility: :private
        })

      activity = %{
        "id" => "https://remote.example/activities/qr3",
        "type" => "QuoteRequest",
        "actor" => @remote_actor,
        "object" => private.uri
      }

      handle(activity, context)

      assert [reject] = queued_deliveries()
      assert reject["type"] == "Reject"
      assert reject["object"]["id"] == activity["id"]
    end

    test "the author can refuse quotes of a public post", context do
      # Posting in the open is not the same as agreeing to be quoted, and the
      # author is the one who decides which of the two they meant.
      closed =
        status_fixture(%{
          account_id: context.local.id,
          uri: "#{URIs.base_url()}/statuses/closed",
          visibility: :public,
          quote_policy: :nobody
        })

      handle(
        %{
          "id" => "https://remote.example/activities/qr4",
          "type" => "QuoteRequest",
          "actor" => @remote_actor,
          "object" => closed.uri
        },
        context
      )

      assert [%{"type" => "Reject"}] = queued_deliveries()
    end

    test "a followers-only quote policy answers a follower and refuses a stranger", context do
      restricted =
        status_fixture(%{
          account_id: context.local.id,
          uri: "#{URIs.base_url()}/statuses/restricted",
          visibility: :public,
          quote_policy: :followers
        })

      theirs =
        status_fixture(%{
          account_id: context.remote.id,
          uri: "https://remote.example/statuses/restricted-quote"
        })

      request = %{
        "id" => "https://remote.example/activities/qr5",
        "type" => "QuoteRequest",
        "actor" => @remote_actor,
        "object" => restricted.uri,
        "instrument" => theirs.uri
      }

      handle(request, context)

      assert [%{"type" => "Reject"}] = queued_deliveries()

      {:ok, _} = Abuuba.Relationships.follow(context.remote, context.local)

      handle(request, context)

      assert "Accept" in Enum.map(queued_deliveries(), & &1["type"])
    end

    test "an Accept of our quote request stores the approval", context do
      Quotes.record(context.quoting, context.quoted.uri, nil)

      activity = %{
        "type" => "Accept",
        "actor" => @remote_actor,
        "object" => %{"type" => "QuoteRequest", "object" => context.quoting.uri},
        "result" => "https://remote.example/approvals/1"
      }

      assert handle(activity, context) == :ok

      assert Repo.one(
               from q in "quotes",
                 where: q.status_id == ^context.quoting.id,
                 select: q.approval_uri
             ) == "https://remote.example/approvals/1"
    end

    test "a Reject of it revokes the quote", context do
      Quotes.record(context.quoting, context.quoted.uri, "https://remote.example/approvals/1")

      activity = %{
        "type" => "Reject",
        "actor" => @remote_actor,
        "object" => %{"type" => "QuoteRequest", "object" => context.quoting.uri}
      }

      assert handle(activity, context) == :ok
      assert Quotes.state(context.quoting.id) == "revoked"
    end
  end
end
