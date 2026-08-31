defmodule AbuubaWeb.ActivityPubController do
  @moduledoc """
  The endpoints other servers fetch: actors, their collections, and their posts.

  Everything here is served as `application/activity+json`. A peer that gets
  `application/json` back will often refuse it, since the content type is how
  it tells an ActivityPub document from any other JSON.

  ## Why the post endpoints exist

  Every document abuuba federates names its post `<actor>/statuses/<id>`, and a
  peer stores that string rather than the post. It comes back to it later: to
  thread a reply that arrived before its parent, to act on an `Announce` that
  carried a bare URI, to check a quote, to re-fetch after an `Update`. So the
  id has to resolve, and it has to resolve to the same document the delivery
  contained.
  """

  use AbuubaWeb, :controller

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Collections
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.FollowerSync
  alias Abuuba.Federation.InstanceActor
  alias Abuuba.Federation.JSONLD
  alias Abuuba.Federation.Quotes
  alias Abuuba.Federation.Serializer
  alias Abuuba.Federation.URIs
  alias Abuuba.Relationships
  alias Abuuba.Relationships.Follow
  alias Abuuba.Repo
  alias Abuuba.Stats
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Status
  alias AbuubaWeb.SignedRequest

  @content_type "application/activity+json"
  @page_size 20
  # The largest value a Postgres `bigint` holds, which is what an id column is.
  @max_snowflake 9_223_372_036_854_775_807
  @replies_page_size 60

  def show(conn, %{"username" => username}) do
    case local_account(username: username) do
      nil -> not_found(conn)
      account -> canonical_actor(conn, account, :username)
    end
  end

  @doc """
  The numeric scheme. An account served here published that shape and other
  servers stored it, so both have to keep working forever.
  """
  def show_by_id(conn, %{"id" => id}) do
    case local_account_by_id(id) do
      nil -> not_found(conn)
      account -> canonical_actor(conn, account, :numeric)
    end
  end

  # "Keep working forever" means arriving at the canonical document, not being
  # handed a copy under the wrong name: strict peers refuse a document whose
  # id is not the URL it came from, so the wrong shape answers with the right
  # one. Permanent, because which shape is canonical never changes for an
  # account.
  defp canonical_actor(conn, %Account{id_scheme: scheme} = account, scheme),
    do: render_actor(conn, account)

  defp canonical_actor(conn, account, _other_scheme) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(external: Actor.id(account))
  end

  def instance_actor(conn, _params) do
    actor = InstanceActor.fetch!()

    conn
    |> put_resp_content_type(@content_type)
    |> json(Actor.render_instance_actor(actor, Accounts.active_keypair(actor)))
  end

  @doc """
  The followers collection, or one server's slice of it.

  With a `domain`, this is the FEP-8fcf partial collection: the answer to "which
  of my accounts do you think follow this one?". A peer asks after its own
  digest disagreed with the one we sent alongside a delivery, and the answer
  lets it repair its list without either side sending the whole thing.
  """
  # Guarded on a string, because `?domain[]=x` arrives as a list and a peer's
  # malformed query must not become our 500. Anything that is not one domain
  # is not a request for one server's slice, so it gets the whole collection.
  def followers(conn, %{"domain" => domain} = params) when is_binary(domain),
    do: partial_collection(conn, params, domain)

  def followers(conn, params), do: collection(conn, params, :followers)

  def following(conn, params), do: collection(conn, params, :following)

  def outbox(conn, params) do
    case author(params) do
      nil ->
        not_found(conn)

      account ->
        collection_id = Actor.id(account) <> "/outbox"
        total = public_status_count(account)

        respond_collection(conn, collection_id, total, params, fn page ->
          # Derived, not read off the row: a post that started here has no `uri`
          # column, so reading it filled the outbox with nulls and a peer
          # walking it got a collection of nothing it could fetch.
          account |> public_statuses(page) |> Enum.map(&Serializer.status_uri(&1, account))
        end)
    end
  end

  @doc """
  One post, as the object every activity about it points at.

  Both URI schemes land here; which one a peer used decides only how the author
  is named in the path.
  """
  def status(conn, params), do: serve_object(conn, params, &render_note/3)

  @doc """
  The activity that carried the post: a `Create`, or an `Announce` for a boost.

  A peer that stored only the activity's id, which is what a delivery's `id`
  is, comes back here rather than to the object.
  """
  def status_activity(conn, params),
    do: serve_object(conn, params, &render_activity/3, "/activity")

  @doc """
  A post's replies, as a page a peer can walk to fill in a thread.

  The author's own replies first, because that is how a thread written by one
  person reads and it is what a peer wants before anything else. Everybody
  else's are behind `only_other_accounts=true`, which is where `next` points
  once the author's run out.
  """
  def status_replies(conn, params) do
    serve_object(conn, params, &render_replies(&1, &2, &3, params))
  end

  @doc """
  How many favourited a post. Never who: see `Actor.counted_collection/3`.
  """
  def status_likes(conn, params) do
    serve_object(conn, params, fn conn, status, account ->
      count = Stats.status_stats(status).favourites_count
      respond_counted(conn, Serializer.likes_uri(status, account), count)
    end)
  end

  @doc """
  How many boosted a post.
  """
  def status_shares(conn, params) do
    serve_object(conn, params, fn conn, status, account ->
      count = Stats.status_stats(status).reblogs_count
      respond_counted(conn, Serializer.shares_uri(status, account), count)
    end)
  end

  @doc """
  What an account has put on its own profile: `featured` for pinned posts,
  `tags` for featured hashtags.

  Any other name is a 404 rather than an empty collection. An empty answer
  would tell a peer that the collection exists and holds nothing, which is not
  true of a name this server does not serve at all.
  """
  def actor_collection(conn, %{"id" => "featured"} = params) do
    with_local_account(conn, params, fn account ->
      pinned = Statuses.pinned(account)

      # In full rather than by reference. A peer rendering a profile would
      # otherwise have to dereference every pin before it could show anything,
      # and `pin/2` only ever accepts a post that is public enough to embed.
      respond(
        conn,
        Actor.whole_collection(
          Actor.collection_id(account, "featured"),
          Enum.map(pinned, &Serializer.note/1)
        )
      )
    end)
  end

  def actor_collection(conn, %{"id" => "tags"} = params) do
    with_local_account(conn, params, fn account ->
      tags = Statuses.featured_tag_names(account)

      respond(
        conn,
        Actor.whole_unordered_collection(
          Actor.collection_id(account, "tags"),
          Enum.map(tags, &Serializer.hashtag/1),
          Serializer.hashtag_context()
        )
      )
    end)
  end

  def actor_collection(conn, _params), do: not_found(conn)

  @doc """
  A curated list of accounts, as another server reads it.

  An `OrderedCollection` of actor ids rather than of actor documents: a peer
  that wants the people has to fetch them anyway, and inlining twenty-five
  actors would make one recommendation into twenty-five profiles this server
  asserts on their behalf.

  Accounts this server has suspended are left out, exactly as they are on the
  page: a list recommending somebody who has been taken down is the one thing
  it must stop doing on its owner's behalf.
  """
  def collection(conn, %{"id" => id}) do
    case Collections.get(id) do
      nil ->
        not_found(conn)

      collection ->
        items =
          collection
          |> Collections.items()
          |> Enum.map(& &1.account_id)
          |> Accounts.get_accounts()
          |> Map.values()
          |> Enum.reject(&(&1.suspended_at != nil))
          |> Enum.map(&Actor.id/1)

        respond(conn, %{
          "@context" => JSONLD.activitystreams(),
          "id" => collection_uri(collection),
          "type" => "OrderedCollection",
          "name" => collection.name,
          "summary" => collection.description || "",
          "attributedTo" => Actor.id(Accounts.get_account(collection.account_id)),
          "totalItems" => length(items),
          "orderedItems" => items
        })
    end
  end

  defp collection_uri(collection) do
    collection.uri || "#{URIs.base_url()}/ap/collections/#{collection.id}"
  end

  @doc """
  The `QuoteAuthorization` this server issued for one post quoting another.

  A peer fetches it rather than believing the quoting server, which is the
  whole point: the approval is served by the quoted author's own host, so an
  approval hosted anywhere else is one the author never gave.
  """
  def quote_authorization(conn, %{"quote_id" => quoting_id} = params) do
    with %Account{suspended_at: nil} = account <- author(params),
         {:ok, quoted_id} <- snowflake(params["id"]),
         %Status{} = quoted <- readable_status(conn, account, quoted_id),
         {:ok, id} <- snowflake(quoting_id),
         %Status{} = quoting <- Statuses.get_status_unchecked(id),
         ^quoted_id <- Quotes.quoted_status_id(quoting) do
      respond(conn, Serializer.quote_authorization(quoting, quoted, fetched_at(conn)))
    else
      _ -> object_not_found(conn)
    end
  end

  ## Objects

  # Missing rather than forbidden, whatever the reason. A 403 on a
  # followers-only post tells a stranger the post exists, which is most of what
  # they were asking; the reference implementation answers 404 for every one of
  # these and so does this.
  # The author is loaded here anyway, so it is handed to the renderer rather
  # than looked up again to build the ids of the collections hanging off it.
  defp serve_object(conn, params, render, suffix \\ "") do
    with %Account{suspended_at: nil} = account <- author(params),
         {:ok, status_id} <- snowflake(params["id"]),
         %Status{} = status <- readable_status(conn, account, status_id) do
      if canonical_shape?(params, account) do
        render.(conn, status, account)
      else
        # The same rule as the actor above: the id that travels is the one
        # shape, and the other answers with it.
        conn
        |> put_status(:moved_permanently)
        |> redirect(external: Serializer.status_uri(status, account) <> suffix)
      end
    else
      _ -> object_not_found(conn)
    end
  end

  defp canonical_shape?(%{"username" => _name}, %Account{id_scheme: scheme}),
    do: scheme == :username

  defp canonical_shape?(%{"account_id" => _id}, %Account{id_scheme: scheme}),
    do: scheme == :numeric

  defp render_note(conn, %Status{reblog_of_id: nil} = status, _account) do
    conn |> put_resp_content_type(@content_type) |> json(Serializer.note(status))
  end

  # A boost has no words of its own, so nothing worth serving sits at its id.
  # The reference implementation sends the asker on to what was boosted and the
  # network has been following that for years.
  defp render_note(conn, %Status{reblog_of_id: reblog_of_id}, _account) do
    case Statuses.get_status_unchecked(reblog_of_id) do
      nil -> object_not_found(conn)
      original -> redirect(conn, external: original_url(original))
    end
  end

  defp render_activity(conn, %Status{} = status, _account) do
    conn |> put_resp_content_type(@content_type) |> json(activity_document(status))
  end

  defp with_local_account(conn, params, render) do
    case author(params) do
      %Account{suspended_at: nil} = account -> render.(account)
      _ -> not_found(conn)
    end
  end

  # The address this document was fetched at, which is the id it has to claim.
  # Built from the request rather than rebuilt from the rows, so the two can
  # never disagree.
  defp fetched_at(conn), do: URIs.base_url() <> conn.request_path

  defp respond(conn, document) do
    conn |> put_resp_content_type(@content_type) |> json(document)
  end

  defp respond_counted(conn, id, total) do
    conn
    |> put_resp_content_type(@content_type)
    |> json(Actor.counted_collection(id, total, context: true))
  end

  # Without `page`, the collection and its first page inline; with it, the page
  # alone. Both shapes are what the reference implementation answers, and a
  # peer walks from one to the other.
  defp render_replies(conn, %Status{} = status, account, params) do
    collection_id = Serializer.replies_uri(status, account)
    others? = truthy?(params["only_other_accounts"])
    # Bounded like any other id off the wire. A min_id no column could hold
    # raises inside the query rather than simply matching nothing.
    min_id =
      case snowflake(params["min_id"]) do
        {:ok, id} -> id
        :error -> nil
      end

    replies =
      Statuses.published_replies(status,
        by: if(others?, do: :others, else: :author),
        limit: @replies_page_size,
        min_id: min_id
      )

    page_uri =
      Serializer.replies_page_uri(collection_id,
        min_id: min_id,
        only_other_accounts: others?
      )

    page =
      Actor.collection_items_page(page_uri,
        part_of: collection_id,
        items: reply_uris(replies),
        next: next_replies(collection_id, replies, others?)
      )

    # A page fetched on its own is a document and declares its vocabulary; the
    # same page nested inside the collection does not, because the collection
    # around it already did.
    document =
      if truthy?(params["page"]) do
        Actor.with_activitystreams_context(page)
      else
        Actor.inline_collection(collection_id, page, context: true)
      end

    conn |> put_resp_content_type(@content_type) |> json(document)
  end

  defp truthy?(value), do: value in ["true", "1", true]

  # A full page means there may be more of the same kind. A short one means the
  # author is done talking, so the walk carries on into everybody else's
  # replies; from there a short page is simply the end.
  defp next_replies(collection_id, replies, others?) do
    cond do
      length(replies) >= @replies_page_size ->
        Serializer.replies_page_uri(collection_id,
          min_id: List.last(replies).id,
          only_other_accounts: others?
        )

      others? ->
        nil

      true ->
        Serializer.replies_page_uri(collection_id, only_other_accounts: true)
    end
  end

  # Each reply named by the id its own server gave it. The authors come back in
  # one query rather than one per reply, which on a busy thread is the
  # difference between one round trip and sixty.
  defp reply_uris([]), do: []

  defp reply_uris(replies) do
    accounts =
      replies
      |> Enum.map(& &1.account_id)
      |> Enum.uniq()
      |> then(&Repo.all(from a in Account, where: a.id in ^&1))
      |> Map.new(&{&1.id, &1})

    Enum.map(replies, &Serializer.status_uri(&1, Map.get(accounts, &1.account_id)))
  end

  defp original_url(%Status{url: url}) when is_binary(url), do: url

  defp original_url(%Status{} = status) do
    URIs.status_url(Repo.get(Account, status.account_id), status.id)
  end

  defp author(%{"username" => username}), do: local_account(username: username)
  defp author(%{"account_id" => account_id}), do: local_account_by_id(account_id)

  # Anonymously first. Almost every fetch here is a peer dereferencing a public
  # post, and answering that without establishing who is asking saves an RSA
  # verification and, for a key we do not hold, an HTTP round trip to a server
  # the asker chose. Only a miss is worth the cost of finding out.
  defp readable_status(conn, account, status_id) do
    case own_status(account, status_id, nil) do
      %Status{} = status -> status
      nil -> own_status(account, status_id, fetching_account(conn))
    end
  end

  # Only this account's own posts, and only the ones that started here. Serving
  # a remote post would mint a second id for something another server has
  # already named, and a peer that dereferenced ours would store the copy.
  defp own_status(%Account{id: account_id}, status_id, viewer) do
    Statuses.not_deleted()
    |> where([s], s.account_id == ^account_id and s.local == true)
    |> Statuses.visible_to(viewer)
    |> Repo.get(status_id)
  end

  defp activity_document(%Status{reblog_of_id: nil} = status), do: Serializer.create(status)
  defp activity_document(%Status{} = status), do: Serializer.announce(status)

  # Who is asking, where they proved it. An absent or unverifiable signature
  # means "nobody in particular" rather than a refusal; by the time this is
  # reached the post was not public anyway, so the only thing an unproven
  # identity costs the asker is the post they were not entitled to.
  defp fetching_account(conn) do
    with true <- List.keymember?(conn.req_headers, "signature", 0),
         {:ok, key_id} <- SignedRequest.verify(conn),
         %Account{} = account <- key_id |> SignedRequest.signer() |> Accounts.get_account_by_uri() do
      account
    else
      _ -> nil
    end
  end

  ## Collections

  # Signed, and only about the asker's own server. A peer is entitled to know
  # which of its accounts follow one of ours, and to nothing else here: the
  # signature says which server is asking, and the domain it asks about has to
  # be that one.
  #
  # `hide_collections` does not apply. Everything in this answer is the peer's
  # own users following an account here, which the peer already has; hiding it
  # would break synchronisation without concealing anything.
  defp partial_collection(conn, %{"username" => username}, domain) do
    with {:ok, key_id} <- SignedRequest.verify(conn),
         :ok <- check_asks_about_itself(key_id, domain),
         %Account{} = account <- local_account(username: username) do
      SignedRequest.record_alive(key_id)

      document =
        Actor.partial_collection(
          FollowerSync.partial_collection_url(account, domain),
          FollowerSync.collection_id(account),
          FollowerSync.follower_uris_on(account, domain)
        )

      conn |> put_resp_content_type(@content_type) |> json(document)
    else
      nil -> not_found(conn)
      {:error, :wrong_domain} -> forbidden(conn)
      {:error, _reason} -> unauthorized(conn)
    end
  end

  defp check_asks_about_itself(key_id, domain) do
    signer_host = key_id |> SignedRequest.signer() |> URIs.host_of()

    if is_binary(signer_host) and signer_host == String.downcase(domain) do
      :ok
    else
      {:error, :wrong_domain}
    end
  end

  # Resolved through `author/1`, which reads whichever of the two id shapes
  # the route carried: the document appends `/followers` to its own id, so
  # both shapes arrive here.
  defp collection(conn, params, which) do
    case author(params) do
      nil -> not_found(conn)
      account -> serve_collection(conn, params, which, account)
    end
  end

  # `nil` for the viewer: a peer fetching a document is nobody in particular,
  # so this asks the setting and stops there, which is the answer this
  # endpoint has always given.
  defp serve_collection(conn, params, which, account) do
    collection_id = "#{Actor.id(account)}/#{which}"

    if Relationships.collections_visible?(account, nil) do
      total = follow_count(account, which)

      respond_collection(conn, collection_id, total, params, fn page ->
        account |> follow_page(which, page) |> Enum.map(&actor_uri_for/1)
      end)
    else
      # Empty, not forbidden. A 403 would tell a stranger there is something
      # here worth hiding, and the point of hiding is that nobody learns
      # anything at all.
      conn
      |> put_resp_content_type(@content_type)
      |> json(Actor.hidden_collection(collection_id))
    end
  end

  defp respond_collection(conn, collection_id, total, params, load_page) do
    conn = put_resp_content_type(conn, @content_type)

    case page_number(params) do
      nil -> json(conn, Actor.collection(collection_id, total))
      page -> json(conn, page_document(collection_id, total, page, load_page))
    end
  end

  defp page_document(collection_id, total, page, load_page) do
    Actor.collection_page(collection_id, load_page.(page),
      page: page,
      total: total,
      page_size: @page_size
    )
  end

  # A page number that is not one is not a page. Clamping to 1 rather than
  # erroring keeps a peer's paging bug from becoming our 500.
  defp page_number(%{"page" => page}) do
    case Integer.parse(to_string(page)) do
      {number, _rest} when number > 0 -> number
      _ -> 1
    end
  end

  defp page_number(_params), do: nil

  ## Queries

  defp render_actor(conn, %Account{suspended_at: nil} = account) do
    conn
    |> put_resp_content_type(@content_type)
    |> json(Actor.render(account, Accounts.active_keypair(account)))
  end

  defp render_actor(conn, %Account{}) do
    # Gone rather than missing, so a peer tombstones instead of retrying.
    conn
    |> put_status(:gone)
    |> json(%{error: gettext("That account is gone.")})
  end

  defp local_account(username: username) do
    case Accounts.get_account_by_handle(username, nil) do
      %Account{domain: nil} = account -> account
      _ -> nil
    end
  end

  defp local_account_by_id(id) do
    with {:ok, account_id} <- snowflake(id),
         %Account{domain: nil} = account <- Repo.get(Account, account_id) do
      account
    else
      _ -> nil
    end
  end

  # An id out of range is a miss, not an error. Handed to a query as written it
  # raises before it can miss, so a typo in somebody's crawler becomes a stream
  # of 500s in our logs rather than the 404 it deserves.
  defp snowflake(value) do
    case Integer.parse(to_string(value)) do
      {id, ""} when id >= 0 and id <= @max_snowflake -> {:ok, id}
      _ -> :error
    end
  end

  defp follow_count(account, :followers) do
    Follow |> where([f], f.target_account_id == ^account.id) |> Repo.aggregate(:count)
  end

  defp follow_count(account, :following) do
    Follow |> where([f], f.account_id == ^account.id) |> Repo.aggregate(:count)
  end

  defp follow_page(account, which, page) do
    {field, select} =
      case which do
        :followers -> {:target_account_id, :account_id}
        :following -> {:account_id, :target_account_id}
      end

    Follow
    |> where([f], field(f, ^field) == ^account.id)
    |> order_by([f], asc: f.id)
    |> offset(^((page - 1) * @page_size))
    |> limit(@page_size)
    |> select([f], field(f, ^select))
    |> Repo.all()
    |> then(&Repo.all(from a in Account, where: a.id in ^&1))
  end

  defp actor_uri_for(%Account{} = account), do: Actor.id(account)

  defp public_status_count(account) do
    account |> public_status_query() |> Repo.aggregate(:count)
  end

  defp public_statuses(account, page) do
    account
    |> public_status_query()
    |> order_by([s], desc: s.id)
    |> offset(^((page - 1) * @page_size))
    |> limit(@page_size)
    |> Repo.all()
  end

  # An outbox is a public endpoint, so it carries only what is already public.
  # Unlisted posts are deliberately absent: unlisted means "not in discovery
  # surfaces", and somebody's outbox is exactly that.
  defp public_status_query(account) do
    Statuses.not_deleted()
    |> where([s], s.account_id == ^account.id and s.visibility == :public)
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: gettext("No such account here.")})
  end

  defp object_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: gettext("No such post here.")})
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: gettext("That request has to be signed.")})
  end

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: gettext("A server may only ask about its own followers.")})
  end
end
