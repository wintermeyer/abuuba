defmodule Abuuba.Federation.Serializer do
  @moduledoc """
  The JSON abuuba sends other servers.

  One module, because the shapes are small and the constraints between them are
  not: an activity has to repeat its object's audience, a `Delete` has to name
  the same id the `Create` used, and an `Undo` has to name the id of the thing
  it takes back. Split across fifteen files those relationships are agreements
  nobody can see; here they are a few lines apart.

  ## Ids are permanent

  Every id here is a promise. A peer stores the id of a post it received and
  echoes it back in a `Like`, an `Announce` or a reply, and it stores the id of
  a `Follow` and echoes it in the `Undo` years later. Changing how one is built
  does not migrate anything; it orphans every reference the rest of the network
  is holding.

  So they follow the reference implementation's shapes exactly:

      <actor>/statuses/<id>            a post
      <actor>/statuses/<id>/activity   the Create or Announce that carried it
      <post>#delete                    its deletion
      <post>#updates/<unix>            one edit of it
      <actor>#follows/<id>             a follow
      <actor>#follows/<id>/undo        taking it back
      <actor>#likes/<id>               a favourite
      <actor>#blocks/<id>              a block

  ## Audience is repeated

  Every activity carries the same `to` and `cc` as the object inside it. A peer
  that filters on the activity's audience never opens the object, so an
  activity that leaves them off delivers to nobody, and one that widens them
  delivers a private post to strangers.

  ## The context is per document

  See `Abuuba.Federation.JSONLD`. A note declares the vocabulary that note uses,
  not the union of everything abuuba can emit, so a plain post does not carry a
  hundred lines of terms for polls and quotes it does not have.

  ## What is not here

  Actor documents and collections are in `Abuuba.Federation.Actor`, which owns
  them because they are what an account *is* rather than something that happens
  to it, and because the endpoints that serve them serve nothing else.

  Polls and custom emoji have no serializer because they have no schema yet.
  There is nothing to serialize, and a serializer written against a guess at
  the shape would be wrong by the time there is.
  """

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.JSONLD
  alias Abuuba.Federation.Quotes
  alias Abuuba.Federation.URIs
  alias Abuuba.Media
  alias Abuuba.Media.Attachment
  alias Abuuba.Media.Upload
  alias Abuuba.Relationships.Block
  alias Abuuba.Relationships.Follow
  alias Abuuba.Relationships.FollowRequest
  alias Abuuba.Repo
  alias Abuuba.Snowflake
  alias Abuuba.Stats
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Conversation
  alias Abuuba.Statuses.Favourite
  alias Abuuba.Statuses.Mention
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.Tag

  @public JSONLD.public()

  # Resolved once rather than rebuilt for every post on every delivery.
  @note_context JSONLD.context([
                  :sensitive,
                  :hashtag,
                  :quote,
                  :conversation,
                  :interaction_policy,
                  :voters_count
                ])
  @note_context_with_blurhash JSONLD.context([
                                :sensitive,
                                :hashtag,
                                :quote,
                                :blurhash,
                                :conversation,
                                :interaction_policy,
                                :voters_count
                              ])
  @hashtag_context JSONLD.context([:hashtag])
  # Five, because the network expects five: Mastodon's protocol documentation
  # says "up to 5 replies from the same server will be fetched upon discovery of
  # a remote status", and that its first page carries the author's own replies
  # while later pages carry everybody else's
  # (https://docs.joinmastodon.org/spec/activitypub/). The `next` links below are
  # read off the wire rather than out of anybody's source: an unauthenticated
  # fetch of a public outbox shows both shapes, and one of each is recorded in
  # `test/support/data/mastodon_replies_collection.json`. Inlining fewer would
  # cost every thread an extra request, inlining more would stop serializing one
  # for delivery being a single small query.
  @inline_replies 5

  ## Objects

  @doc """
  A post, as the object other servers store.
  """
  @spec note(Status.t()) :: map()
  def note(%Status{} = status) do
    account = account_of(status)
    mentions = mentioned_accounts(status)
    {to, cc} = audience(status, account, mentions)
    attachments = Media.for_status(status)

    %{
      "@context" => note_context(attachments),
      "id" => status_uri(status, account),
      "type" => "Note",
      "attributedTo" => Actor.id(account),
      "content" => Statuses.content_html(status),
      "published" => timestamp(status.inserted_at),
      # Explicitly null rather than absent: an absent key means the same thing
      # and the network sends the null.
      "inReplyTo" => in_reply_to(status),
      # An account a moderator here marked travels marked: a peer has no way to
      # know about our decision otherwise, and the picture would be uncovered
      # everywhere except on this server.
      "sensitive" => status.sensitive or account.sensitized_at != nil,
      "to" => to,
      "cc" => cc,
      "tag" => Enum.map(mentions, &mention_tag/1) ++ Enum.map(tags_of(status), &hashtag/1),
      "attachment" => Enum.map(attachments, &document/1),
      # The page a person reads the post on, which is not the id. A peer renders
      # this behind "open original", so falling back to the id sent every reader
      # who clicked it to a JSON document.
      "url" => status.url || URIs.status_url(account, status.id)
    }
    |> put_poll(status)
    |> put_content_map(status)
    |> Map.put("interactionPolicy", interaction_policy(status, account))
    |> maybe_put("conversation", conversation_uri(status))
    |> maybe_put("summary", presence(status.spoiler_text))
    |> maybe_put("updated", status.edited_at && timestamp(status.edited_at))
    |> put_quote(status)
    |> put_collections(status, account)
  end

  # The language a post was written in, which travels nowhere else in
  # ActivityPub: `contentMap` is a map of language to the same content, and
  # reading the key back out is how every server on the network learns what
  # language a post is in.
  #
  # It was not sent at all, so every post this server federated arrived
  # language-less -- and a reader whose timeline is filtered to one language,
  # or who wanted the translate button, got neither. Our own parser reads
  # `contentMap` and has all along, which is how this surfaced: a post written
  # here, serialised here and read back here came out with no language.
  defp put_content_map(object, %Status{language: language}) when is_binary(language) do
    Map.put(object, "contentMap", %{language => object["content"]})
  end

  defp put_content_map(object, _status), do: object

  # What holds a thread together when its posts arrive out of order, which over
  # asynchronous delivery is ordinary. `conversation` rather than `context`
  # because that is the field the rest of the network reads: the reference
  # implementation has threaded on it for a decade and resolves its own back to
  # a local row, which is exactly what `Statuses.upsert_conversation/1` does
  # with ours.
  defp conversation_uri(%Status{conversation_id: nil}), do: nil

  defp conversation_uri(%Status{conversation_id: id}) do
    case Repo.get(Conversation, id) do
      nil -> nil
      conversation -> URIs.conversation_uri(conversation)
    end
  end

  # An approved quote travels in three spellings, because the network is midway
  # through agreeing on one: `quote` is the spec, `quoteUri` and
  # `_misskey_quote` are what servers were already reading before there was a
  # spec. The approval rides along so a peer can check it rather than take our
  # word for it.
  defp put_quote(document, %Status{} = status) do
    case Quotes.accepted_quote(status) do
      nil ->
        document

      %{uri: uri} ->
        document
        |> Map.put("quote", uri)
        |> Map.put("quoteUri", uri)
        |> Map.put("_misskey_quote", uri)
        |> maybe_put("quoteAuthorization", Quotes.approval_uri(status))
    end
  end

  # Only on a post that started here. Another server's post is republished as
  # it was written, and attaching collections of ours would claim to speak for
  # a thread we do not own.
  defp put_collections(document, %Status{local: false}, _account), do: document

  defp put_collections(document, %Status{} = status, account) do
    counts = Stats.status_stats(status)

    document
    |> Map.put("replies", inline_replies(status, account))
    |> Map.put(
      "likes",
      Actor.counted_collection(likes_uri(status, account), counts.favourites_count)
    )
    |> Map.put(
      "shares",
      Actor.counted_collection(shares_uri(status, account), counts.reblogs_count)
    )
  end

  # The author's own first few replies, inline. A peer that fetched the post
  # then has the start of the thread without a second request, which is most of
  # what it wanted; `next` carries it on to the rest.
  defp inline_replies(%Status{} = status, account) do
    collection_id = replies_uri(status, account)
    replies = Statuses.published_replies(status, by: :author, limit: @inline_replies)

    page =
      Actor.collection_items_page(collection_id <> "?page=true",
        part_of: collection_id,
        items: Enum.map(replies, &status_uri(&1, account)),
        next: next_replies_page(collection_id, replies)
      )

    Actor.inline_collection(collection_id, page)
  end

  # Carry on through the author's own replies while there were any, and hand
  # over to everybody else's when there were not. A peer following this walks
  # the whole thread without ever being told how long it is. Both query strings
  # are the ones a Mastodon post carries on the wire; see `@inline_replies`.
  defp next_replies_page(collection_id, []),
    do: replies_page_uri(collection_id, only_other_accounts: true)

  defp next_replies_page(collection_id, replies),
    do: replies_page_uri(collection_id, min_id: List.last(replies).id)

  @doc """
  A hashtag, as it appears in a `tag` list or in a featured-tags collection.

  `href` points at this server's page for the tag. It is what a peer puts
  behind the name it renders, so it has to be somewhere a reader can actually
  land.
  """
  @spec hashtag(Tag.t()) :: map()
  def hashtag(%Tag{name: name} = tag) do
    %{
      "type" => "Hashtag",
      # Encoded, because a tag may be any word in any script and an unescaped
      # one is not a URL a peer can follow.
      "href" => "#{URIs.base_url()}/tags/#{URI.encode(name, &URI.char_unreserved?/1)}",
      "name" => "##{tag.display_name || name}"
    }
  end

  @doc """
  The vocabulary a document made of hashtags declares.
  """
  @spec hashtag_context() :: term()
  def hashtag_context, do: @hashtag_context

  @doc """
  The `QuoteAuthorization` this server issues for a quote of one of its posts.

  FEP-044f. It is what tells the rest of the network that the quoted author
  agreed, and it names both posts so an approval to quote one post cannot be
  replayed for another.
  """
  @spec quote_authorization(Status.t(), Status.t(), String.t()) :: map()
  def quote_authorization(%Status{} = quoting, %Status{} = quoted, id) do
    %{
      "@context" => JSONLD.context([:quote_authorization]),
      "id" => id,
      "type" => "QuoteAuthorization",
      "attributedTo" => Actor.id(account_of(quoted)),
      "interactingObject" => status_uri(quoting),
      "interactionTarget" => status_uri(quoted)
    }
  end

  @doc """
  The address of a post's `replies` collection.
  """
  @spec replies_uri(Status.t(), Account.t() | nil) :: String.t()
  def replies_uri(status, account \\ nil), do: status_uri(status, account) <> "/replies"

  @doc """
  One page of a post's `replies` collection, addressed the way a peer walks it.

  Every `next` link is built here, by the note's inline collection and by the
  endpoint that serves the pages alike. The two used to spell the same query
  string separately, so renaming a parameter on one side would have left the
  other pointing at an address nobody answers, and the endpoint's own tests
  would still have passed.
  """
  @spec replies_page_uri(String.t(), keyword()) :: String.t()
  def replies_page_uri(collection_id, opts \\ []) do
    query =
      [
        {"page", "true"},
        opts[:min_id] && {"min_id", opts[:min_id]},
        opts[:only_other_accounts] && {"only_other_accounts", "true"}
      ]
      |> Enum.filter(&is_tuple/1)

    "#{collection_id}?#{URI.encode_query(query)}"
  end

  @doc """
  The address of a post's `likes` collection.
  """
  @spec likes_uri(Status.t(), Account.t() | nil) :: String.t()
  def likes_uri(status, account \\ nil), do: status_uri(status, account) <> "/likes"

  @doc """
  The address of a post's `shares` collection.
  """
  @spec shares_uri(Status.t(), Account.t() | nil) :: String.t()
  def shares_uri(status, account \\ nil), do: status_uri(status, account) <> "/shares"

  ## Activities about posts

  @doc """
  The `Create` that carries a new post.
  """
  @spec create(Status.t()) :: map()
  def create(%Status{} = status) do
    object = note(status)

    wrap("Create", object["id"] <> "/activity", status, object)
  end

  @doc """
  The `Announce` that carries a boost.

  The object is the boosted post's id rather than the post itself. Embedding it
  would mean asserting what somebody else wrote, in our name, at whatever it
  said when we last looked.
  """
  @spec announce(Status.t()) :: map()
  def announce(%Status{reblog_of_id: reblog_of_id} = status) when not is_nil(reblog_of_id) do
    original = Repo.get(Status, reblog_of_id)
    account = account_of(status)
    original_account = original && Repo.get(Account, original.account_id)
    {to, cc} = audience(status, account, [])

    %{
      "@context" => JSONLD.activitystreams(),
      "id" => status_uri(status, account) <> "/activity",
      "type" => "Announce",
      "actor" => Actor.id(account),
      "published" => timestamp(status.inserted_at),
      "object" => original && status_uri(original, original_account),
      "to" => to,
      # The boosted author, so that a boost is something they hear about.
      "cc" => Enum.uniq(cc ++ List.wrap(original_account && Actor.id(original_account)))
    }
  end

  @doc """
  The `Update` for one edit of a post.

  The id names the edit rather than the post, so a peer that receives two edits
  can tell them apart and can tell a redelivery from a new one.
  """
  @spec update(Status.t()) :: map()
  def update(%Status{} = status) do
    object = note(status)
    edited = status.edited_at || status.updated_at

    wrap("Update", "#{object["id"]}#updates/#{DateTime.to_unix(edited)}", status, object)
  end

  @doc """
  The `Delete` for a post.

  A `Tombstone` rather than nothing, because a peer has to be able to tell "this
  was deleted" from "this never arrived", and only the first justifies removing
  it from everybody's timeline.
  """
  @spec delete(Status.t()) :: map()
  def delete(%Status{} = status) do
    account = account_of(status)
    uri = status_uri(status, account)

    %{
      "@context" => JSONLD.activitystreams(),
      "id" => uri <> "#delete",
      "type" => "Delete",
      "actor" => Actor.id(account),
      "object" => %{"id" => uri, "type" => "Tombstone", "atomUri" => uri},
      # Everybody, whoever the post reached. A deletion narrower than the post
      # leaves copies behind on servers that got it and not this.
      "to" => [@public]
    }
  end

  @doc """
  The `Delete` for an account that is going away.
  """
  @spec delete_actor(Account.t()) :: map()
  def delete_actor(%Account{} = account) do
    uri = Actor.id(account)

    %{
      "@context" => JSONLD.activitystreams(),
      "id" => uri <> "#delete",
      "type" => "Delete",
      "actor" => uri,
      "object" => uri,
      "to" => [@public]
    }
  end

  ## Activities about relationships

  @doc """
  The `Follow` one account sends another.
  """
  @spec follow(Follow.t() | FollowRequest.t()) :: map()
  def follow(edge) do
    Map.put(follow_document(edge), "@context", JSONLD.activitystreams())
  end

  @doc """
  The `Accept` that turns a request into a follow.
  """
  @spec accept(FollowRequest.t()) :: map()
  def accept(%FollowRequest{} = request), do: answer("Accept", request)

  @doc """
  The `Reject` that turns it down.
  """
  @spec reject(FollowRequest.t()) :: map()
  def reject(%FollowRequest{} = request), do: answer("Reject", request)

  @doc """
  The answer to a `Follow` that arrived from another server.

  Built from the activity as it was received rather than from the row it
  created, because what a peer matches an answer against is the document it
  sent. An `Accept` naming our own id for the same follow is an answer to
  nothing it recognises, and its follow stays pending for ever.

  The id is derived from the incoming one, so a redelivered `Follow` is
  answered with the same `Accept` twice rather than with two of them.
  """
  @spec answer_to(String.t(), Account.t(), map()) :: map()
  def answer_to(type, %Account{} = target, activity) when type in ~w(Accept Reject) do
    %{
      "@context" => JSONLD.activitystreams(),
      "id" => "#{Actor.id(target)}##{String.downcase(type)}s/#{fragment_for(activity)}",
      "type" => type,
      "actor" => Actor.id(target),
      "object" => Map.delete(activity, "@context"),
      "to" => [activity["actor"]] |> Enum.reject(&is_nil/1)
    }
  end

  # An id that arrived may hold anything, including the `#` that would make
  # this two fragments, so it is encoded rather than pasted in.
  defp fragment_for(%{"id" => id}) when is_binary(id) and id != "",
    do: URI.encode_www_form(id)

  defp fragment_for(_activity), do: Ecto.UUID.generate()

  @doc """
  The `Undo` that takes an activity back.

  Built from the activity rather than from the row, because the id it has to
  name is the id the peer stored, and that is the one we sent.
  """
  @spec undo(map()) :: map()
  def undo(%{"id" => id, "actor" => actor} = activity) do
    %{
      "@context" => JSONLD.activitystreams(),
      "id" => id <> "/undo",
      "type" => "Undo",
      "actor" => actor,
      "object" => Map.delete(activity, "@context")
    }
    |> maybe_put("to", activity["to"])
  end

  @doc """
  The `Like` for a favourite.
  """
  @spec like(Favourite.t()) :: map()
  def like(%Favourite{} = favourite) do
    account = Repo.get(Account, favourite.account_id)
    status = Repo.get(Status, favourite.status_id)
    author = status && Repo.get(Account, status.account_id)

    %{
      "@context" => JSONLD.activitystreams(),
      "id" => "#{Actor.id(account)}#likes/#{favourite.id}",
      "type" => "Like",
      "actor" => Actor.id(account),
      "object" => status && status_uri(status, author)
    }
  end

  @doc """
  The `Block` one account sends another.

  Addressed to the blocked account and nobody else. A block is not news for the
  blocker's followers, and a peer that saw it in a public audience would have
  learned something the blocker never chose to publish.
  """
  @spec block(Block.t()) :: map()
  def block(%Block{} = block) do
    account = Repo.get(Account, block.account_id)
    target = Repo.get(Account, block.target_account_id)

    %{
      "@context" => JSONLD.activitystreams(),
      "id" => "#{Actor.id(account)}#blocks/#{block.id}",
      "type" => "Block",
      "actor" => Actor.id(account),
      "object" => target && Actor.id(target),
      "to" => [target && Actor.id(target)] |> Enum.reject(&is_nil/1)
    }
  end

  @doc """
  The `Update` that tells peers a profile changed.

  The whole actor document as the object, which is what the reference
  implementation sends: a peer applies it wholesale rather than diffing, so a
  partial object would blank whatever it left out. No key material goes in it,
  because the document is built without one.
  """
  @spec update_actor(Account.t()) :: map()
  def update_actor(%Account{} = account) do
    uri = Actor.id(account)

    %{
      "@context" => JSONLD.activitystreams(),
      # Stamped with the time, so a peer receiving two edits out of order can
      # tell which is the later one. The id is per edit rather than per account
      # for the same reason.
      "id" => "#{uri}#updates/#{DateTime.to_unix(DateTime.utc_now())}",
      "type" => "Update",
      "actor" => uri,
      # With the key. The document inside an Update is the actor as the other
      # server will store it, so it has to be the whole actor -- rendered
      # without the keypair it carried `"publicKey": null`, and GoToSocial
      # refused to convert it at all: `ExtractPubKeyFromActor: public key
      # property was nil`. A profile change from here never showed there, and
      # Mastodon tolerating it is why nothing said so.
      "object" => Actor.render(account, Accounts.active_keypair(account)),
      "to" => [@public]
    }
  end

  @doc """
  The `Move` telling followers an account is now somewhere else.
  """
  @spec move(Account.t(), String.t()) :: map()
  def move(%Account{} = account, target_uri) do
    uri = Actor.id(account)

    %{
      "@context" => JSONLD.activitystreams(),
      # From when the move happened, not from now. An id off the current clock
      # makes every redelivery look like a fresh move, and a peer that already
      # followed the pointer follows it again.
      "id" => "#{uri}#moves/#{DateTime.to_unix(account.moved_at || account.updated_at)}",
      "type" => "Move",
      "actor" => uri,
      "object" => uri,
      "target" => target_uri,
      "to" => [Actor.followers_id(account)]
    }
  end

  @doc """
  The `Flag` that reports an account to its own server.

  Signed and attributed to this server rather than to the person who
  complained. Naming the reporter would tell the reported account's server, and
  through it the reported account, who objected to them.
  """
  @spec flag(Account.t(), [Status.t()], String.t(), integer() | nil) :: map()
  def flag(target, statuses, comment, report_id \\ nil)

  def flag(%Account{} = target, statuses, comment, report_id) do
    objects = [Actor.id(target) | Enum.map(statuses, &status_uri(&1, target))]

    %{
      "@context" => JSONLD.activitystreams(),
      # From the report's own row where there is one, so a redelivery carries
      # the id the receiving server already has and is recognised as the same
      # report rather than a second one.
      "id" => "#{URIs.base_url()}/reports/#{report_id || Snowflake.generate()}",
      "type" => "Flag",
      "actor" => "#{URIs.base_url()}/actor",
      "content" => comment,
      "object" => objects,
      "to" => [Actor.id(target)]
    }
  end

  @doc """
  The `Add` that pins a post to an account's featured collection.
  """
  @spec add(Account.t(), Status.t()) :: map()
  def add(%Account{} = account, %Status{} = status), do: featured("Add", account, status)

  @doc """
  The `Remove` that unpins it.
  """
  @spec remove(Account.t(), Status.t()) :: map()
  def remove(%Account{} = account, %Status{} = status), do: featured("Remove", account, status)

  @doc """
  A post's permanent id.
  """
  @spec status_uri(Status.t(), Account.t() | nil) :: String.t()
  def status_uri(status, account \\ nil)
  def status_uri(%Status{uri: uri}, _account) when is_binary(uri), do: uri

  def status_uri(%Status{} = status, account) do
    "#{Actor.id(account || account_of(status))}/statuses/#{status.id}"
  end

  @doc """
  A vote on somebody else's poll.

  A `Note` with a `name` and no body, replying to the question. That shape is
  the whole of it on the wire: there is no vote activity, and a server reading
  this as an ordinary reply would show a post whose entire text is the name of
  an option.
  """
  @spec vote(Poll.t(), Account.t(), non_neg_integer()) :: map()
  def vote(%Poll{} = poll, %Account{} = voter, choice) do
    status = Repo.get(Status, poll.status_id)
    author = Repo.get(Account, poll.account_id)
    actor = Actor.id(voter)
    to = [author && Actor.id(author)] |> Enum.reject(&is_nil/1)

    # Derived from the poll and the choice rather than from a row, so a
    # redelivery carries the id the peer already has and counts once.
    id = "#{actor}#votes/#{poll.id}/#{choice}"

    %{
      "@context" => JSONLD.activitystreams(),
      "id" => id <> "/activity",
      "type" => "Create",
      "actor" => actor,
      "to" => to,
      "object" => %{
        "id" => id,
        "type" => "Note",
        "name" => Enum.at(poll.options, choice),
        "attributedTo" => actor,
        "inReplyTo" => status && status_uri(status),
        "to" => to
      }
    }
  end

  @doc """
  The `Add` that puts a hashtag on a profile.

  Aimed at the featured collection rather than at the tags collection, which is
  wrong on its face and is what the reference implementation sends: nothing
  stores a collection URI for tags, and every receiver in the network works out
  which collection is meant from the type of the object inside. Sending the
  correct target would be sending one nothing understands.
  """
  @spec add_tag(Account.t(), Tag.t()) :: map()
  def add_tag(%Account{} = account, %Tag{} = tag), do: featured_tag("Add", account, tag)

  @doc """
  The `Remove` that takes it off again.
  """
  @spec remove_tag(Account.t(), Tag.t()) :: map()
  def remove_tag(%Account{} = account, %Tag{} = tag), do: featured_tag("Remove", account, tag)

  ## Building blocks

  defp featured_tag(type, account, tag) do
    uri = Actor.id(account)

    %{
      "@context" => hashtag_context(),
      "id" => "#{uri}##{String.downcase(type)}s/tags/#{tag.id}",
      "type" => type,
      "actor" => uri,
      "object" => hashtag(tag),
      "target" => "#{uri}/collections/featured",
      "to" => [@public]
    }
  end

  defp featured(type, account, status) do
    uri = Actor.id(account)

    %{
      "@context" => JSONLD.activitystreams(),
      "id" => "#{uri}##{String.downcase(type)}s/#{status.id}",
      "type" => type,
      "actor" => uri,
      "object" => status_uri(status, account),
      "target" => "#{uri}/collections/featured",
      "to" => [@public]
    }
  end

  defp answer(type, %FollowRequest{} = request) do
    target = Repo.get(Account, request.target_account_id)
    follower = Repo.get(Account, request.account_id)
    inner = follow_document(request, follower, target)

    %{
      "@context" => JSONLD.activitystreams(),
      "id" => "#{Actor.id(target)}##{String.downcase(type)}s/follows/#{request.id}",
      "type" => type,
      "actor" => Actor.id(target),
      "object" => inner,
      "to" => [follower && Actor.id(follower)] |> Enum.reject(&is_nil/1)
    }
  end

  # The peer's own id where it sent one, because that is the string it stored
  # and the string it will name when it takes the follow back.
  defp follow_document(edge, follower \\ nil, target \\ nil) do
    follower = follower || Repo.get(Account, edge.account_id)
    target = target || Repo.get(Account, edge.target_account_id)

    %{
      "id" => edge.uri || "#{Actor.id(follower)}#follows/#{edge.id}",
      "type" => "Follow",
      "actor" => Actor.id(follower),
      "object" => target && Actor.id(target)
    }
  end

  # An activity around an object it already has, carrying the object's audience
  # and the object's context. The actor comes off the object rather than being
  # looked up again: it is the same account, one query ago.
  defp wrap(type, id, %Status{} = status, object) do
    %{
      "@context" => object["@context"],
      "id" => id,
      "type" => type,
      "actor" => object["attributedTo"],
      "published" => timestamp(status.inserted_at),
      "object" => Map.delete(object, "@context"),
      "to" => object["to"],
      "cc" => object["cc"]
    }
  end

  # Derived from visibility, which is how ActivityPub says it. Public names the
  # public collection in `to`; unlisted moves it to `cc`, which is the whole of
  # what "keep this out of discovery surfaces" means on the wire.
  defp audience(%Status{visibility: :public}, account, mentions) do
    {[@public], [Actor.followers_id(account) | mention_uris(mentions)]}
  end

  defp audience(%Status{visibility: :unlisted}, account, mentions) do
    {[Actor.followers_id(account)], [@public | mention_uris(mentions)]}
  end

  defp audience(%Status{visibility: :private}, account, mentions) do
    {[Actor.followers_id(account) | mention_uris(mentions)], []}
  end

  # Limited is addressed exactly like direct: the people it names and nobody
  # else, with no followers collection and no public. The two differ in what a
  # client shows, not in who is entitled to receive it, which is also how the
  # reference implementation addresses them.
  defp audience(%Status{visibility: visibility}, _account, mentions)
       when visibility in [:direct, :limited] do
    {mention_uris(mentions), []}
  end

  defp mention_uris(mentions), do: Enum.map(mentions, &Actor.id/1)

  defp mention_tag(%Account{} = account) do
    %{
      "type" => "Mention",
      "href" => Actor.id(account),
      "name" => "@" <> URIs.full_handle(account)
    }
  end

  # Declared only where it is used, which is what the rest of this module does
  # with every extension term. A term the context does not declare is one any
  # consumer that compacts the document throws away, so the field would look
  # present and be absent; declaring it on a post with no pictures is noise in
  # every plain note this server sends.
  # A poll is a Question rather than a Note, and the difference is the whole
  # feature: a reader that sees a Note shows the text and nothing else, which
  # is how a poll federated as a Note arrives everywhere as a post with the
  # options missing.
  #
  # `oneOf` and `anyOf` are not interchangeable -- one is radio buttons and the
  # other is checkboxes -- so the key carries the multiple-choice flag rather
  # than a field beside it.
  defp put_poll(note, status) do
    case Statuses.get_poll(status) do
      nil ->
        note

      poll ->
        note
        |> Map.put("type", "Question")
        |> Map.put(if(poll.multiple, do: "anyOf", else: "oneOf"), poll_options(poll))
        |> maybe_put("endTime", poll_time(poll.expires_at))
        |> maybe_put("closed", poll_time(closed_at(poll)))
        |> maybe_put("votersCount", poll.voters_count)
    end
  end

  # Each option carries its own count, in a `replies` collection, because that
  # is where a Question keeps them: there is no tally array on the wire.
  defp poll_options(poll) do
    tallies = poll.tallies || []

    poll.options
    |> Enum.with_index()
    |> Enum.map(fn {name, index} ->
      %{
        "type" => "Note",
        "name" => name,
        "replies" => %{
          "type" => "Collection",
          "totalItems" => Enum.at(tallies, index) || 0
        }
      }
    end)
  end

  # Said only once it is true. A `closed` on a poll still running would tell
  # every reader it was over.
  defp closed_at(%{expires_at: nil}), do: nil

  defp closed_at(%{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :lt, do: expires_at
  end

  # Seconds, which is what the rest of the network writes and reads. The
  # microseconds abuuba stores would be legal and would still be the only server
  # sending them.
  defp poll_time(nil), do: nil
  defp poll_time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # Who may interact with this post, said out loud rather than left to be
  # guessed at.
  #
  # A server reads this to decide whether to let its own user act at all. With
  # nothing here, Mastodon records that nobody may quote the post and never
  # sends a QuoteRequest, so answering quote requests correctly is not enough
  # to be quotable.
  #
  # Both spellings, because two generations of the same vocabulary are in the
  # wild and a server reads only the one it knows. GoToSocial 0.19 reads
  # `always` and `approvalRequired`; Mastodon reads `automaticApproval` and
  # `manualApproval`. Publishing only the second was worse than publishing
  # none: GoToSocial read the policy, found no `always` under `canReply`, and
  # answered its own user "you do not have permission to reply to this status"
  # -- every abuuba post unrepliable from there, from one added field.
  #
  # `approvalRequired` is always empty. abuuba decides by policy rather than by
  # asking the author, so there is no queue waiting on a person and nothing
  # truthful to put in it.
  defp interaction_policy(%Status{} = status, account) do
    audience = interaction_audience(status, account)

    %{
      "canLike" => permission(audience),
      "canReply" => permission(audience),
      "canAnnounce" => permission(announce_audience(status, account)),
      "canQuote" => permission(quote_audience(status, account))
    }
  end

  defp permission(audience) do
    %{
      "always" => audience,
      "approvalRequired" => [],
      "automaticApproval" => audience,
      "manualApproval" => []
    }
  end

  # Whoever the post was addressed to. Somebody who cannot read a post cannot
  # reply to it either, and claiming otherwise invites a peer to try and be
  # refused by us.
  defp interaction_audience(%Status{visibility: visibility}, _account)
       when visibility in [:public, :unlisted],
       do: [@public]

  defp interaction_audience(%Status{visibility: :private}, account),
    do: [Actor.followers_id(account)]

  defp interaction_audience(_status, account), do: [Actor.id(account)]

  # A boost carries a post to an audience its author did not choose, so only
  # one already addressed to everybody can be boosted by anybody.
  defp announce_audience(%Status{visibility: visibility}, _account)
       when visibility in [:public, :unlisted],
       do: [@public]

  defp announce_audience(_status, account), do: [Actor.id(account)]

  # A separate question from who may read it: posting in the open is not the
  # same as agreeing to be quoted, and the author answers that one themselves.
  #
  # "Nobody" is the author's own actor rather than an empty list, because an
  # empty list is what a policy that was never set looks like and the two mean
  # opposite things.
  defp quote_audience(%Status{quote_policy: :public} = status, account) do
    if status.visibility in [:public, :unlisted], do: [@public], else: [Actor.id(account)]
  end

  defp quote_audience(%Status{quote_policy: :followers}, account),
    do: [Actor.followers_id(account)]

  defp quote_audience(_status, account), do: [Actor.id(account)]

  defp note_context(attachments) do
    if Enum.any?(attachments, &(&1.blurhash not in [nil, ""])) do
      @note_context_with_blurhash
    else
      @note_context
    end
  end

  # One picture, video or sound file, in the shape every server reads.
  #
  # `name` is the alt text, and it is the field this must never drop: a picture
  # with no description is a picture some readers cannot read at all, and the
  # description its author wrote here is the only one that will ever exist.
  #
  # `blurhash` and the dimensions are not in the specification and are read by
  # most of the network, because they are what lets a client hold the space and
  # show something before the bytes arrive.
  defp document(%Attachment{} = attachment) do
    %{
      "type" => "Document",
      "mediaType" => attachment.file_content_type,
      "url" => Upload.url(attachment)
    }
    |> maybe_put("name", presence(attachment.description))
    |> maybe_put("blurhash", presence(attachment.blurhash))
    |> maybe_put("width", dimension(attachment, "width"))
    |> maybe_put("height", dimension(attachment, "height"))
  end

  defp dimension(%Attachment{meta: meta}, key) when is_map(meta) do
    case get_in(meta, ["original", key]) do
      value when is_integer(value) -> value
      _absent -> nil
    end
  end

  defp dimension(_attachment, _key), do: nil

  # The spelling somebody typed for the name, because that is what a reader
  # sees; the casefolded one for the link, because #Caturday and #caturday are
  # one tag and one timeline.
  defp in_reply_to(%Status{in_reply_to_id: nil}), do: nil

  defp in_reply_to(%Status{in_reply_to_id: id}) do
    case Repo.get(Status, id) do
      nil -> nil
      parent -> status_uri(parent, Repo.get(Account, parent.account_id))
    end
  end

  defp account_of(%Status{account: %Account{} = account}), do: account
  defp account_of(%Status{account_id: id}), do: Repo.get(Account, id)

  defp mentioned_accounts(%Status{id: status_id}) do
    Mention
    |> join(:inner, [m], a in Account, on: a.id == m.account_id)
    |> where([m], m.status_id == ^status_id)
    |> order_by([m], asc: m.id)
    |> select([_m, a], a)
    |> Repo.all()
  end

  defp tags_of(%Status{id: status_id}) do
    Tag
    |> join(:inner, [t], st in "statuses_tags", on: st.tag_id == t.id)
    |> where([_t, st], st.status_id == ^status_id)
    |> order_by([t], asc: t.id)
    |> Repo.all()
  end

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_value), do: nil

  defp maybe_put(document, _key, nil), do: document
  defp maybe_put(document, key, value), do: Map.put(document, key, value)
end
