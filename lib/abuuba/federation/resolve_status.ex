defmodule Abuuba.Federation.ResolveStatus do
  @moduledoc """
  Fetching a post from another server, and deciding whether to believe it.

  ## The attribution rule

  One check does most of the work here: an object's `id` and its
  `attributedTo` have to be on the same host. That is the difference between
  "somebody's server says they wrote this" and "somebody's server says
  *anybody* wrote this".

  Without it, `evil.example` publishes an object with
  `"attributedTo": "https://good.example/users/alice"` and every server that
  dereferences it files a post under Alice's name that she never wrote. The
  attack costs nothing, works against every account on every host, and leaves
  the victim with no way to notice. The rule is cheap and absolute, so it is
  applied on every path that turns a document into a status: create, update
  and delete alike.

  ## The refetch dance

  A URL is not an identity. Fetching `https://host/x` may return a document
  whose `id` is `https://host/y`, and the `id` is what everything else keys on.
  So when they differ, the document is fetched again by its own `id` and the
  answer has to agree with itself. A server that will not answer for its own
  stated id is not one to take a post from.

  ## Depth and discovery limits

  Resolving a reply means resolving what it replies to, and that chain is
  attacker-controlled: a thread a thousand deep is a thousand requests we make
  because somebody asked. Both the depth and the number of new objects any one
  request may discover are capped.
  """

  alias Abuuba.Accounts
  alias Abuuba.Conversations
  alias Abuuba.Federation.HTTP
  alias Abuuba.Federation.JSONLD
  alias Abuuba.Federation.Limits
  alias Abuuba.Federation.Quotes
  alias Abuuba.Federation.ResolveActor
  alias Abuuba.Instance
  alias Abuuba.Media
  alias Abuuba.Moderation.Domains
  alias Abuuba.Repo
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Formatter
  alias Abuuba.Statuses.Status

  # Objects that are posts.
  @post_types ~w(Note Question)

  # Objects that are not posts but that people link to and reply to. Kept as a
  # link rather than dropped: a reply to a blog post should still show what it
  # is replying to, and inventing body text for something that is not a post
  # would put words in somebody's mouth.
  @link_only_types ~w(Article Page Image Audio Video Event Document)

  # Wrappers that carry an object rather than being one.
  @wrapper_types ~w(Create Update Announce)

  @max_thread_depth 20
  @max_discoveries_per_request 20

  @doc """
  Whether an object's id and its author are on the same host.

  The single most important check in this module. See the moduledoc.
  """
  @spec trustworthy_attribution?(String.t() | nil, term()) :: boolean()
  def trustworthy_attribution?(object_id, attributed_to) do
    with author when is_binary(author) <- attribution_uri(attributed_to),
         %URI{host: object_host} when is_binary(object_host) <- URI.parse(object_id || ""),
         %URI{host: author_host} when is_binary(author_host) <- URI.parse(author) do
      String.downcase(object_host) == String.downcase(author_host)
    else
      _ -> false
    end
  end

  @doc """
  The actor URI out of an `attributedTo`, which arrives in several shapes.
  """
  @spec attribution_uri(term()) :: String.t() | nil
  def attribution_uri(value) when is_binary(value), do: value
  def attribution_uri(%{"id" => id}) when is_binary(id), do: id

  # A list is legal and means co-authorship, which nothing in the fediverse
  # renders. The first entry is the author every implementation uses.
  def attribution_uri([first | _rest]), do: attribution_uri(first)
  def attribution_uri(_value), do: nil

  @doc """
  Fetches and stores the status at `uri`.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, Status.t()} | {:error, atom()}
  def resolve(uri, opts \\ []) do
    case Statuses.get_status_unchecked_by_uri(uri) do
      %Status{} = status -> {:ok, status}
      nil -> fetch_and_store(uri, opts)
    end
  end

  @doc """
  Fetches a status again whatever we already hold.

  Separate from `resolve/2`, which answers from what we have: only a request
  that actually goes out can discover that the peer has removed the post, and
  their 404 is the only notice we are ever going to get.
  """
  @spec refresh(String.t(), keyword()) :: {:ok, Status.t()} | {:error, atom()}
  def refresh(uri, opts \\ []), do: fetch_and_store(uri, opts)

  @doc """
  Stores a status from a document a peer pushed to us, rather than one we went
  and fetched.

  Same checks: a document that arrived in an inbox is no more trustworthy than
  one we asked for, and in fact rather less, since we did not choose to ask.
  """
  @spec from_document(map(), keyword()) :: {:ok, Status.t()} | {:error, atom()}
  def from_document(document, opts \\ []) do
    with {:ok, object} <- unwrap(document),
         :ok <- check_object(object),
         {:ok, account} <- resolve_author(object, opts) do
      upsert(object, account, opts)
    end
  end

  @doc """
  Handles a peer telling us a status is gone, or a fetch finding it gone.
  """
  @spec forget(String.t()) :: :ok
  def forget(uri) do
    case Statuses.get_status_unchecked_by_uri(uri) do
      nil -> :ok
      status -> with {:ok, _} <- Statuses.delete_status(status), do: :ok
    end
  end

  ## Fetching

  defp fetch_and_store(uri, opts) do
    with {:ok, document} <- fetch(uri, opts),
         {:ok, object} <- unwrap(document),
         {:ok, object} <- refetch_by_id(object, uri, opts),
         :ok <- check_object(object),
         {:ok, account} <- resolve_author(object, opts),
         {:ok, status} <- upsert(object, account, opts) do
      {:ok, status}
    else
      # A status the peer no longer has is one we should stop showing. Their
      # 404 is the only notice we are going to get.
      {:error, reason} when reason in [:not_found, :gone] ->
        forget(uri)
        {:error, reason}

      other ->
        other
    end
  end

  defp fetch(uri, opts) do
    case Keyword.get(opts, :fetch) do
      nil -> HTTP.get_json(uri, opts)
      fetcher -> fetcher.(uri)
    end
  end

  # A URL is not an identity. If the document names a different id, fetch it
  # again by that id and require the answer to agree with itself; a server that
  # will not answer for its own stated id is not one to take a post from.
  defp refetch_by_id(object, requested_uri, opts) do
    id = object["id"]

    cond do
      not is_binary(id) ->
        {:error, :object_without_id}

      same_uri?(id, requested_uri) ->
        {:ok, object}

      Keyword.get(opts, :refetched, false) ->
        # Already been round once. A second disagreement is a server playing
        # games rather than a redirect.
        {:error, :id_mismatch}

      true ->
        refetch(id, opts)
    end
  end

  defp refetch(id, opts) do
    with {:ok, document} <- fetch(id, Keyword.put(opts, :refetched, true)),
         {:ok, object} <- unwrap(document) do
      if same_uri?(object["id"], id), do: {:ok, object}, else: {:error, :id_mismatch}
    end
  end

  defp same_uri?(a, b) when is_binary(a) and is_binary(b) do
    String.downcase(String.trim_trailing(a, "/")) ==
      String.downcase(String.trim_trailing(b, "/"))
  end

  defp same_uri?(_a, _b), do: false

  ## Shape

  @doc """
  Pulls the object out of a wrapper, or takes the document as the object.

  Both shapes are in the wild: a peer may hand back a bare `Note`, or a
  `Create` carrying one.
  """
  @spec unwrap(term()) :: {:ok, map()} | {:error, :malformed_object}
  def unwrap(%{"type" => type, "object" => object}) when type in @wrapper_types do
    case object do
      %{} = embedded -> {:ok, embedded}
      # An object given only as a URI is a reference, not a document. Fetching
      # it is the caller's job, not something to guess at here.
      _uri -> {:error, :malformed_object}
    end
  end

  def unwrap(%{} = document), do: {:ok, document}
  def unwrap(_document), do: {:error, :malformed_object}

  defp check_object(object) do
    cond do
      not is_map(object) ->
        {:error, :malformed_object}

      not is_binary(object["id"]) ->
        {:error, :object_without_id}

      object["type"] not in (@post_types ++ @link_only_types) ->
        {:error, :unsupported_object_type}

      # The rule the whole module is arranged around.
      not trustworthy_attribution?(object["id"], object["attributedTo"]) ->
        {:error, :untrustworthy_attribution}

      true ->
        :ok
    end
  end

  defp resolve_author(object, opts) do
    author_uri = attribution_uri(object["attributedTo"])

    case Keyword.get(opts, :resolve_actor) do
      nil -> ResolveActor.resolve(author_uri, opts)
      resolver -> resolver.(author_uri)
    end
  end

  ## Storing

  defp upsert(object, account, opts) do
    attrs = attributes(object, account, opts)

    result =
      case Statuses.get_status_unchecked_by_uri(object["id"]) do
        nil -> Statuses.create_status(attrs)
        status -> Statuses.update_remote_status(status, attrs)
      end

    with {:ok, status} <- result do
      apply_tags(status, object)
      apply_media(status, object, account)
      apply_quote(status, object)
      apply_poll(status, object)

      # After the tags, because the conversation is built out of who the post
      # mentions and a post arriving from elsewhere records that here rather
      # than when it is created. Delivered at creation like a local one, it
      # found nobody in the conversation but the sender, and a direct message
      # landed in the inbox of the person it was written to -- which is the
      # only place it was ever going to be read. Idempotent, so the local
      # path's own delivery is not undone or doubled.
      Conversations.deliver(status)

      {:ok, status}
    end
  end

  # The poll, where the post is a Question.
  #
  # Read on every delivery rather than only the first, because the counts are
  # the part that moves: a poll whose tallies are stored once and never again
  # is a poll that federated and then went stale in front of the reader.
  defp apply_poll(status, object) do
    Statuses.replace_remote_poll(status, poll_attrs(object))
  end

  # `oneOf` is a single choice and `anyOf` is several, and which key carries
  # the options is the only place that distinction lives on the wire.
  defp poll_attrs(%{} = object) do
    cond do
      is_list(object["oneOf"]) -> poll_attrs(object, object["oneOf"], false)
      is_list(object["anyOf"]) -> poll_attrs(object, object["anyOf"], true)
      true -> nil
    end
  end

  defp poll_attrs(_object), do: nil

  defp poll_attrs(object, choices, multiple) do
    named = Enum.filter(choices, &is_binary(&1["name"]))

    %{
      options: Enum.map(named, & &1["name"]),
      tallies: Enum.map(named, &option_count/1),
      multiple: multiple,
      # `toot:votersCount` is Mastodon's extension rather than part of
      # ActivityStreams, so a peer that never sends it is not misbehaving.
      # Passing the key with a nil in it overrode the column's own default and
      # raised on the NOT NULL constraint, which meant a poll from such a
      # server could not federate to us at all.
      voters_count: object["votersCount"] || 0,
      # `closed` where a peer sends that instead: both name the moment voting
      # ended, and a poll with neither simply never closes.
      expires_at: poll_time(object["endTime"] || object["closed"]),
      uri: object["id"],
      last_fetched_at: DateTime.utc_now()
    }
  end

  defp option_count(%{"replies" => %{"totalItems" => total}}) when is_integer(total), do: total
  defp option_count(_option), do: 0

  defp poll_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _unparseable -> nil
    end
  end

  defp poll_time(_value), do: nil

  # The pictures, video and sound a post arrived with.
  #
  # Recorded, not fetched: the row keeps the address it came from and the media
  # proxy pulls the bytes the first time a reader here opens the post. A server
  # that downloaded every attachment on delivery would spend its disk on posts
  # nobody read.
  #
  # Rewritten from scratch on a redelivery rather than added to, because a
  # sender that edited a post sends the whole object again and the difference
  # between "one more picture" and "the same picture twice" is not in it.
  defp apply_media(status, object, account) do
    documents =
      if Domains.reject_media?(account.domain) do
        # Nothing recorded rather than a row with no bytes behind it: a reader
        # is better served by a post with no pictures than by a broken one, and
        # a row that can never be filled is a row somebody has to explain
        # later.
        []
      else
        listed_documents(object)
      end

    Media.replace_remote(status, Enum.map(documents, &remote_attachment_attrs/1))
  end

  defp listed_documents(object) do
    object
    |> Map.get("attachment")
    |> List.wrap()
    |> Enum.filter(&fetchable_document?/1)
    # A sender listing forty pictures is a sender this server does not have
    # to believe.
    |> Enum.take(Instance.max_media_attachments())
  end

  defp fetchable_document?(%{} = document), do: href(document["url"]) != nil
  defp fetchable_document?(_document), do: false

  defp remote_attachment_attrs(document) do
    %{
      remote_url: href(document["url"]),
      file_content_type: document["mediaType"],
      # `summary` first, then `name`. Both are used for alt text across the
      # network, and reading only one drops the description on every server
      # that writes the other — which is the field a picture cannot spare.
      # Cut rather than refused, like every other field a stranger sends. Ours
      # are capped at the same number, so a longer one used to fail the
      # changeset and take the picture's description with it -- on the field a
      # picture can least spare.
      description: Limits.media_description(document["summary"] || document["name"]),
      blurhash: presence(document["blurhash"]),
      meta: meta_for(document)
    }
  end

  # `url` is a string, an object with `href`, or a list of either. All three are
  # legal and all three are sent; reading only the first dropped the picture
  # without a trace.
  defp href(url) when is_binary(url), do: presence(url)
  defp href(%{"href" => href}), do: href(href)
  defp href([first | rest]), do: href(first) || href(rest)
  defp href(_url), do: nil

  defp meta_for(document) do
    document
    |> dimensions()
    |> put_preview(document["icon"])
  end

  # The sender's own thumbnail, where they published one. Without it the small
  # style is fetched from the full-size address, which works and costs a reader
  # the whole photograph to see it at four hundred pixels wide.
  defp put_preview(meta, icon) when is_map(icon) or is_binary(icon) or is_list(icon) do
    case href(icon_url(icon)) do
      nil -> meta
      url -> Map.put(meta, "preview_remote_url", url)
    end
  end

  defp put_preview(meta, _icon), do: meta

  defp icon_url(%{"url" => url}), do: url
  defp icon_url(icon), do: icon

  defp dimensions(%{"width" => width, "height" => height})
       when is_integer(width) and is_integer(height) do
    %{"original" => %{"width" => width, "height" => height}}
  end

  defp dimensions(_document), do: %{}

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  # A quote is recorded but never accepted here. Whether the quoted author
  # agreed is a separate question with its own fetch, and answering it inline
  # would make storing one post depend on another server answering.
  defp apply_quote(status, object) do
    case Quotes.quoted_uri(object) do
      nil -> :ok
      uri -> Quotes.record(status, uri, approval_uri(object))
    end
  end

  defp approval_uri(object) do
    case object["quoteAuthorization"] do
      uri when is_binary(uri) -> uri
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  # Mentions and hashtags come from the `tag` array rather than from parsing the
  # text. The sender has already worked out who it addressed and under which
  # tags, and re-deriving that from HTML would disagree with them on exactly the
  # cases that matter: a handle written differently, or a tag in a language
  # whose word boundaries we get wrong.
  defp apply_tags(status, object) do
    tags = List.wrap(object["tag"])

    Enum.each(tags, fn
      %{"type" => "Mention", "href" => href} when is_binary(href) -> mention(status, href)
      %{"type" => "Hashtag", "name" => name} when is_binary(name) -> hashtag(status, name)
      _ -> :ok
    end)

    # Their emoji, kept under their domain. A post reading `hello :blobcat:`
    # otherwise renders the shortcode as text, because ours cannot be lent to
    # it: `:blobcat:` there and `:blobcat:` here are two pictures with one name.
    Instance.put_remote_emoji(tags, author_domain(status))
  end

  defp author_domain(status) do
    case Accounts.get_account(status.account_id) do
      %{domain: domain} -> domain
      _ -> nil
    end
  end

  # Only accounts we already hold. A mention of somebody nobody here has heard
  # of is not a reason to go and fetch them: it would let any post make us
  # resolve any actor, which is a fetch amplifier pointed at whoever the sender
  # names.
  defp mention(status, href) do
    case Accounts.get_account_by_uri(href) do
      nil -> :ok
      account -> Statuses.mention(status, account)
    end
  end

  defp hashtag(status, name) do
    with {:ok, tag} <- Statuses.upsert_tag(name) do
      Statuses.tag_status(status, tag)
    end
  end

  defp attributes(object, account, opts) do
    %{
      account_id: account.id,
      uri: object["id"],
      url: string_or_nil(object["url"]) || object["id"],
      local: false,
      text: body_for(object),
      spoiler_text: Limits.spoiler(object["summary"]),
      # Or the author is one our own moderators marked, in which case what they
      # said about their own post does not decide it.
      sensitive: object["sensitive"] == true or account.sensitized_at != nil,
      language: language(object),
      visibility: visibility(object),
      in_reply_to_id: reply_target(object, opts),
      conversation_id: conversation_target(object),
      edited_at: parse_time(object["updated"])
    }
  end

  # Something that is not a post keeps only its link. Inventing body text for
  # an article would put words in somebody's mouth, and dropping it entirely
  # would leave a reply pointing at nothing.
  defp body_for(%{"type" => type} = object) when type in @link_only_types do
    string_or_nil(object["url"]) || object["id"]
  end

  # Cleaned on the way in rather than on the way out. Their markup is written
  # by somebody we have no reason to trust and ends up inside a reader's page,
  # and a renderer that has to remember to sanitize is one that eventually
  # forgets.
  defp body_for(object) do
    object["content"] |> string_or_default("") |> Formatter.sanitize()
  end

  defp language(%{"contentMap" => map}) when is_map(map) do
    map |> Map.keys() |> List.first()
  end

  defp language(_object), do: nil

  # Derived from the audience, which is how ActivityPub says it: addressed to
  # the public collection is public, the same collection in cc is unlisted,
  # followers-only is private, and anything else is direct.
  @public JSONLD.public()

  defp visibility(object) do
    to = addressees(object["to"])
    cc = addressees(object["cc"])

    cond do
      @public in to -> :public
      @public in cc -> :unlisted
      Enum.any?(to, &String.ends_with?(&1, "/followers")) -> :private
      true -> :direct
    end
  end

  defp addressees(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp addressees(value) when is_binary(value), do: [value]
  defp addressees(_value), do: []

  # Only if we already hold it. Following the chain is `resolve_thread/2`'s
  # job, and doing it here would make storing one post fetch a whole thread.
  # What the sender calls the thread. The only thing that holds one together
  # when its posts arrive out of order, which over asynchronous delivery is
  # ordinary: a reply routinely turns up before the post it answers, and
  # `inReplyTo` then names something this server has never seen.
  #
  # `nil` where the sender names none, which leaves `create_status/2` to derive
  # one — from the parent if it is here, or a fresh one if it is not.
  defp conversation_target(object) do
    case object["conversation"] do
      uri when is_binary(uri) and uri != "" ->
        case Statuses.upsert_conversation(uri) do
          {:ok, conversation} -> conversation.id
          _error -> nil
        end

      _absent ->
        nil
    end
  end

  defp reply_target(object, _opts) do
    case object["inReplyTo"] do
      uri when is_binary(uri) ->
        case Statuses.get_status_unchecked_by_uri(uri) do
          nil -> nil
          status -> status.id
        end

      _ ->
        nil
    end
  end

  ## Threads

  @doc """
  Resolves a status and as much of what it replies to as the limits allow.

  Hitting a limit truncates the ancestry rather than failing: the post somebody
  asked for is still a real post, and refusing to show it because its
  great-great-grandparent was unreachable helps nobody. What the limits stop is
  the walking, and the walking is what is attacker-controlled — a thread a
  thousand deep is a thousand requests we make because somebody asked us to.
  """
  @spec resolve_thread(String.t(), keyword()) :: {:ok, Status.t()} | {:error, atom()}
  def resolve_thread(uri, opts \\ []) do
    depth = Keyword.get(opts, :max_depth, @max_thread_depth)
    budget = Keyword.get(opts, :max_discoveries, @max_discoveries_per_request)

    walk(uri, opts, depth, budget)
  end

  defp walk(_uri, _opts, 0, _budget), do: {:error, :thread_too_deep}
  defp walk(_uri, _opts, _depth, 0), do: {:error, :discovery_budget_exhausted}

  defp walk(uri, opts, depth, budget) do
    with {:ok, document} <- fetch(uri, opts),
         {:ok, object} <- unwrap(document) do
      parent_id = resolve_parent(object, opts, depth, budget)

      case from_document(object, opts) do
        {:ok, status} -> {:ok, attach_parent(status, parent_id)}
        error -> error
      end
    end
  end

  defp resolve_parent(object, opts, depth, budget) do
    with uri when is_binary(uri) <- object["inReplyTo"],
         nil <- Statuses.get_status_unchecked_by_uri(uri),
         {:ok, parent} <- walk(uri, opts, depth - 1, budget - 1) do
      parent.id
    else
      %Status{id: id} -> id
      _ -> nil
    end
  end

  defp attach_parent(status, nil), do: status

  defp attach_parent(status, parent_id) do
    parent = Repo.get(Status, parent_id)

    {:ok, updated} =
      Statuses.update_remote_status(status, %{
        in_reply_to_id: parent_id,
        in_reply_to_account_id: parent && parent.account_id
      })

    updated
  end

  ## Small helpers

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  defp string_or_default(value, _default) when is_binary(value), do: value
  defp string_or_default(_value, default), do: default

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp parse_time(_value), do: nil

  @doc """
  How deep a reply chain may be followed.
  """
  def max_thread_depth, do: @max_thread_depth

  @doc """
  How many new objects one request may cause us to fetch.
  """
  def max_discoveries_per_request, do: @max_discoveries_per_request
end
