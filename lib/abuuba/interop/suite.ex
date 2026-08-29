defmodule Abuuba.Interop.Suite do
  @moduledoc """
  What the interop sandbox checks, named once.

  The fediverse punishes protocol drift silently. Nothing returns an error when
  two servers stop agreeing: posts simply do not arrive, follows sit unaccepted,
  and the first anybody hears is a person saying they cannot see somebody. So
  the point of this list is that it is a list — a scenario that stops being run
  should be a missing row in a report rather than a thing nobody remembered.

  The runner reads it to know what to run and a test reads it to check the
  suite still covers what it set out to. Neither of them knows the scenarios
  individually; both ask here.

  ## Implementations

  Three others, chosen because between them they cover the dialects most of the
  network speaks: Mastodon, GoToSocial and Akkoma. A scenario names which of
  them it applies to, because not all of them have all of the features — asking
  a server about a feature it does not implement produces a failure that means
  nothing.
  """

  @implementations [
    %{
      id: :mastodon,
      name: "Mastodon",
      # The one most of the network runs, and the one whose quirks other
      # implementations copied.
      dialects: [:cavage, :rfc9421]
    },
    %{
      id: :gotosocial,
      name: "GoToSocial",
      dialects: [:cavage]
    }

    # Akkoma is not here because it publishes no container image, so the suite
    # cannot bring one up — see the note in test/interop/compose.yml. A column
    # that can never be filled is worse than no column: it reads as sixteen
    # things nobody has checked rather than as a decision.
  ]

  @scenarios [
    %{
      id: :follow_out,
      name: "Follow a remote account",
      proves: "an outbound Follow is accepted and the Accept comes back",
      applies_to: :all
    },
    %{
      id: :follow_in,
      name: "Be followed by a remote account",
      proves: "an inbound Follow is accepted and the follower appears",
      applies_to: :all
    },
    %{
      id: :unfollow,
      name: "A follow can be taken back",
      proves: "an Undo of a Follow travels, both when they send it and when we do",
      applies_to: :all
    },
    %{
      id: :follow_locked,
      name: "Follow a locked account",
      proves: "a Follow becomes a request, and the later Accept turns it into a follow",
      applies_to: :all
    },
    %{
      id: :post_propagation,
      name: "A post reaches followers",
      proves: "a Create is delivered and appears in a remote follower's timeline",
      applies_to: :all
    },
    %{
      id: :reply,
      name: "A reply threads",
      proves: "inReplyTo is honoured in both directions",
      applies_to: :all
    },
    %{
      id: :mention,
      name: "A mention is heard",
      proves: "a post naming an account here arrives as a mention notification",
      applies_to: :all
    },
    %{
      id: :boost,
      name: "A boost carries",
      proves: "an Announce renders as a boost of the original, and its Undo takes it back",
      applies_to: :all
    },
    %{
      id: :followers_only,
      name: "A followers-only post stays with the followers",
      proves: "a private post reaches a follower elsewhere and no stranger",
      applies_to: :all
    },
    %{
      id: :direct_message,
      name: "A direct message stays direct",
      proves: "a direct post reaches the account it names and no timeline",
      applies_to: :all
    },
    %{
      id: :edit,
      name: "An edit is applied",
      proves: "an Update replaces the text rather than making a second post",
      applies_to: :all
    },
    %{
      id: :delete,
      name: "A delete removes",
      proves: "a Delete removes the post on the other side",
      applies_to: :all
    },
    %{
      id: :edit_in,
      name: "An edit from them is applied here",
      proves: "an Update arriving replaces the words rather than adding a post",
      applies_to: [:mastodon, :gotosocial]
    },
    %{
      id: :delete_in,
      name: "A delete from them removes it here",
      proves: "a Delete arriving is honoured rather than filed",
      applies_to: [:mastodon, :gotosocial]
    },
    %{
      id: :media,
      name: "Media arrives",
      proves: "an attachment is fetched and its description survives",
      applies_to: :all
    },
    %{
      id: :favourite,
      name: "A favourite, and taking it back",
      proves: "a Like is counted and its Undo takes the count back down",
      applies_to: :all
    },
    %{
      id: :content_warning,
      name: "A content warning survives",
      proves: "summary arrives as a warning rather than as body text",
      applies_to: :all
    },
    %{
      id: :pin,
      name: "A pinned post travels",
      proves: "an Add puts a post on the profile elsewhere and a Remove takes it off",
      # GoToSocial 0.19 answers both with "unhandled object type", in its own
      # log, so asking it produces a failure about a feature it does not have.
      # It still shows a pin it finds when it fetches the featured collection;
      # what it does not do is hear about one changing.
      applies_to: [:mastodon]
    },
    %{
      id: :poll,
      name: "A poll and its votes",
      proves: "a Question federates and a remote vote is counted",
      applies_to: [:mastodon, :gotosocial]
    },
    %{
      id: :quote,
      name: "A quote request",
      proves: "a QuoteRequest is answered and the quote renders",
      applies_to: [:mastodon]
    },
    %{
      id: :profile_update,
      name: "A profile change travels",
      proves: "an Update of the actor reaches a server that follows it",
      applies_to: :all
    },
    %{
      id: :move,
      name: "A Move is honoured",
      proves: "followers are moved when the target claims the origin back",
      applies_to: [:mastodon]
    },
    %{
      id: :block,
      name: "A block holds",
      proves: "a blocked account's posts stop arriving, and the old ones go",
      applies_to: :all
    },
    %{
      id: :follow_rejected,
      name: "A follow request can be declined",
      proves: "a Reject clears what the side that asked was claiming",
      applies_to: :all
    },
    %{
      id: :block_in,
      name: "A block from them holds here",
      proves: "an inbound Block takes the follows down in both directions",
      applies_to: :all
    },
    %{
      id: :report_forwarding,
      name: "A forwarded report arrives",
      proves: "a Flag reaches the server of the account it is about",
      # Only where the suite can read the other server's moderation queue.
      # GoToSocial has no admin API the scenario can ask, and checking that we
      # sent one is not what this is for.
      applies_to: [:mastodon]
    },
    %{
      id: :report_in,
      name: "A forwarded report arrives here",
      proves: "a Flag from another server reaches this one's moderators",
      # Mastodon can be told to forward a report over its own API. GoToSocial
      # has no equivalent the suite can drive, and checking that we would have
      # received one is not what this is for.
      applies_to: [:mastodon]
    },
    %{
      id: :account_closure,
      name: "A closed account goes",
      proves: "a Delete of the actor reaches a server that followed them",
      applies_to: :all
    },
    %{
      id: :domain_block,
      name: "A domain block holds",
      proves: "nothing from a blocked domain arrives, in either direction",
      applies_to: :all
    },
    %{
      id: :signatures,
      name: "Signatures verify in both directions",
      proves: "each implementation's signing dialect is accepted, and ours by it",
      applies_to: :all
    },
    %{
      id: :authorized_fetch,
      name: "Authorized fetch",
      proves: "a signed GET is required and answered when the peer insists on one",
      applies_to: :all
    }
  ]

  @doc """
  Every scenario, in the order the runner runs them.

  Ordered rather than sorted: a follow has to work before a post can be
  observed arriving, and a report that fails everything because step one failed
  is easier to read than sixteen unrelated failures.
  """
  @spec scenarios() :: [map()]
  def scenarios, do: @scenarios

  @doc """
  Every implementation the sandbox brings up.
  """
  @spec implementations() :: [map()]
  def implementations, do: @implementations

  @doc """
  One scenario by id.
  """
  @spec scenario(atom()) :: map() | nil
  def scenario(id), do: Enum.find(@scenarios, &(&1.id == id))

  @doc """
  Whether a scenario is asked of an implementation.
  """
  @spec applies?(map(), atom()) :: boolean()
  def applies?(%{applies_to: :all}, _implementation), do: true
  def applies?(%{applies_to: list}, implementation), do: implementation in list

  @doc """
  The scenarios one implementation is asked.
  """
  @spec for_implementation(atom()) :: [map()]
  def for_implementation(implementation) do
    Enum.filter(@scenarios, &applies?(&1, implementation))
  end
end
