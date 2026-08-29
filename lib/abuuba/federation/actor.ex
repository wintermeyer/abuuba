defmodule Abuuba.Federation.Actor do
  @moduledoc """
  The ActivityPub actor document: what other servers fetch to learn who an
  account is.

  The `id` in here is the account's permanent name on the fediverse. Every
  server that has ever seen a post, a follow or a mention from this account has
  stored that string, so it is not a URL that can be tidied up later. That is
  why the scheme is recorded per account rather than derived: an account taken
  over from another server keeps answering on whichever shape it already
  published, because serving the other one would not redirect anybody, it would
  orphan every relationship pointing at the old one.
  """

  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Keypair
  alias Abuuba.Federation.JSONLD
  alias Abuuba.Federation.Signature
  alias Abuuba.Federation.URIs
  alias Abuuba.Media.ProfileImages

  # An actor document signs, so it needs the security vocabulary; the rest is
  # what an actor actually says about itself. Assembled rather than written out
  # so that one definition of `toot:discoverable` serves every document that
  # uses it. See `Abuuba.Federation.JSONLD`.
  @context JSONLD.context([
             :security,
             :manually_approves_followers,
             :discoverable,
             :indexable,
             :memorial,
             :attribution_domains,
             :featured,
             :property_value
           ])

  @doc """
  The actor id for a local account, in whichever scheme it uses.

  Delegated rather than implemented twice: this and `Abuuba.Federation.URIs` both
  used to decide it, with clauses in a different order, and an account whose id
  is not built from its username came out differently depending on which one
  was asked.
  """
  @spec id(Account.t()) :: String.t()
  defdelegate id(account), to: URIs, as: :actor_uri

  @doc """
  An account's followers collection.

  Load-bearing beyond being a URL: a post addressed to it is a followers-only
  post, and `Abuuba.Federation.ResolveStatus` reads a peer's visibility back out
  of that same shape. One definition, so the two directions cannot disagree.
  """
  @spec followers_id(Account.t()) :: String.t()
  def followers_id(%Account{} = account), do: id(account) <> "/followers"

  @doc """
  The actor document for a local account.
  """
  @spec render(Account.t(), Keypair.t() | nil) :: map()
  def render(%Account{} = account, keypair \\ nil) do
    actor_id = id(account)

    %{
      "@context" => @context,
      "id" => actor_id,
      "type" => actor_type(account),
      "preferredUsername" => account.username,
      "name" => account.display_name,
      "summary" => account.note,
      "url" => URIs.profile_url(account),
      "manuallyApprovesFollowers" => account.locked,
      "discoverable" => account.discoverable,
      "indexable" => account.indexable,
      # A moderator's decision about somebody who has died, and the peers who
      # show an "in memoriam" profile can only do so if they are told.
      "memorial" => account.memorial,
      # The sites this person allows to name them as an author. Published
      # because the server showing the link preview is the one that has to
      # check the claim, and it is never this one.
      "attributionDomains" => account.attribution_domains,
      "published" => published(account),
      "inbox" => actor_id <> "/inbox",
      "outbox" => actor_id <> "/outbox",
      "followers" => actor_id <> "/followers",
      "following" => actor_id <> "/following",
      "endpoints" => %{"sharedInbox" => URIs.shared_inbox_url()},
      "publicKey" => public_key(actor_id, keypair),
      "attachment" => Enum.map(account.fields || [], &property_value/1),
      # What this account has put on its own profile. Advertised even when both
      # are empty, because a peer that finds no property at all cannot tell an
      # account with nothing pinned from a server that does not publish pins.
      "featured" => collection_id(account, "featured"),
      "featuredTags" => collection_id(account, "tags")
    }
    |> put_movement(account)
    |> Map.merge(ProfileImages.actor_properties(account))
    |> reject_nils()
  end

  @doc """
  The address of one of an account's own collections: `featured` or `tags`.
  """
  @spec collection_id(Account.t(), String.t()) :: String.t()
  def collection_id(%Account{} = account, name), do: "#{id(account)}/collections/#{name}"

  @doc """
  The document for the server's own actor.

  Deliberately thin. It signs server-level fetches and nothing else: it has no
  posts, no followers and no profile, so every field that would describe a
  person is simply absent rather than empty.
  """
  @spec render_instance_actor(Account.t(), Keypair.t() | nil) :: map()
  def render_instance_actor(%Account{} = account, keypair \\ nil) do
    actor_id = URIs.base_url() <> "/actor"

    %{
      "@context" => @context,
      "id" => actor_id,
      "type" => "Application",
      "preferredUsername" => account.username,
      "url" => actor_id,
      "manuallyApprovesFollowers" => true,
      "discoverable" => false,
      "indexable" => false,
      "inbox" => actor_id <> "/inbox",
      "endpoints" => %{"sharedInbox" => URIs.shared_inbox_url()},
      "publicKey" => public_key(actor_id, keypair)
    }
    |> reject_nils()
  end

  @doc """
  An `OrderedCollection` that only advertises its size and its first page.

  Collections are fetched by strangers, so the first response is a header
  rather than the contents: a server with a hundred thousand followers must not
  serialise all of them because somebody opened a profile.
  """
  @spec collection(String.t(), non_neg_integer()) :: map()
  def collection(collection_id, total) do
    %{
      "@context" => JSONLD.activitystreams(),
      "id" => collection_id,
      "type" => "OrderedCollection",
      "totalItems" => total,
      "first" => collection_id <> "?page=1"
    }
  end

  @doc """
  One page of a collection.
  """
  @spec collection_page(String.t(), [term()], keyword()) :: map()
  def collection_page(collection_id, items, opts) do
    page = Keyword.fetch!(opts, :page)
    total = Keyword.fetch!(opts, :total)
    page_size = Keyword.fetch!(opts, :page_size)

    %{
      "@context" => JSONLD.activitystreams(),
      "id" => "#{collection_id}?page=#{page}",
      "type" => "OrderedCollectionPage",
      "partOf" => collection_id,
      "totalItems" => total,
      "orderedItems" => items
    }
    |> maybe_next(collection_id, page, total, page_size)
  end

  @doc """
  A collection whose size is the whole answer.

  `likes` and `shares` on a post are this: a peer is told how many, never who.
  Naming them would hand anybody who asked a list of the people who read a
  post, which is not something they agreed to by favouriting it, and the
  reference implementation publishes the count alone for the same reason.

  Unordered, because there is nothing to order.
  """
  @spec counted_collection(String.t(), non_neg_integer(), keyword()) :: map()
  def counted_collection(collection_id, total, opts \\ []) do
    with_context(%{"id" => collection_id, "type" => "Collection", "totalItems" => total}, opts)
  end

  @doc """
  An unordered collection that hands out its first page inline.

  A post's replies. Inline rather than by reference so a peer that fetched the
  post has the start of the thread without a second request, which is most of
  what it wanted.
  """
  @spec inline_collection(String.t(), map(), keyword()) :: map()
  def inline_collection(collection_id, first_page, opts \\ []) do
    with_context(%{"id" => collection_id, "type" => "Collection", "first" => first_page}, opts)
  end

  @doc """
  One page of an unordered collection, walked forward by `min_id` rather than
  by page number.

  A thread grows while it is being read, and a page number moves under the
  reader every time somebody replies. An id does not.
  """
  @spec collection_items_page(String.t(), keyword()) :: map()
  def collection_items_page(page_id, opts) do
    %{
      "id" => page_id,
      "type" => "CollectionPage",
      "partOf" => Keyword.fetch!(opts, :part_of),
      "items" => Keyword.fetch!(opts, :items)
    }
    |> maybe_put("next", opts[:next])
  end

  @doc """
  An ordered collection with its contents inline rather than paged.

  For a collection that is small by construction. An account's pinned posts are
  capped, so paging it would be three round trips to fetch five things and a
  peer rendering a profile wants all of them at once anyway.
  """
  @spec whole_collection(String.t(), [term()]) :: map()
  def whole_collection(collection_id, items) do
    %{
      "@context" => JSONLD.activitystreams(),
      "id" => collection_id,
      "type" => "OrderedCollection",
      "totalItems" => length(items),
      "orderedItems" => items
    }
  end

  @doc """
  The same, unordered, and declaring whatever terms its items use.

  Featured tags: they have no order worth publishing, and a `Hashtag` is not a
  term the bare ActivityStreams vocabulary defines.
  """
  @spec whole_unordered_collection(String.t(), [term()], term()) :: map()
  def whole_unordered_collection(collection_id, items, context) do
    %{
      "@context" => context,
      "id" => collection_id,
      "type" => "Collection",
      "totalItems" => length(items),
      "items" => items
    }
  end

  @doc """
  Declares the ActivityStreams vocabulary on a document that is being served on
  its own rather than nested inside another.
  """
  @spec with_activitystreams_context(map()) :: map()
  def with_activitystreams_context(document),
    do: Map.put(document, "@context", JSONLD.activitystreams())

  @doc """
  A collection that is deliberately only part of a larger one.

  Not a page: a page is one slice of an ordering everybody can walk, while this
  is the whole of what one asker is entitled to. `partOf` is what says so.
  """
  @spec partial_collection(String.t(), String.t(), [term()]) :: map()
  def partial_collection(id, part_of, items) do
    %{
      "@context" => JSONLD.activitystreams(),
      "id" => id,
      "type" => "OrderedCollection",
      "partOf" => part_of,
      "totalItems" => length(items),
      "orderedItems" => items
    }
  end

  @doc """
  An empty collection, which is what a hidden one looks like from outside.

  Hidden rather than refused: a 403 tells a stranger that the account has
  followers worth hiding, and the point of hiding is that nobody learns
  anything.
  """
  @spec hidden_collection(String.t()) :: map()
  def hidden_collection(collection_id) do
    %{
      "@context" => JSONLD.activitystreams(),
      "id" => collection_id,
      "type" => "OrderedCollection",
      "totalItems" => 0
    }
  end

  defp maybe_next(page_map, collection_id, page, total, page_size) do
    if page * page_size < total do
      Map.put(page_map, "next", "#{collection_id}?page=#{page + 1}")
    else
      page_map
    end
  end

  defp actor_type(%Account{actor_type: type}) do
    type |> Atom.to_string() |> String.capitalize() |> normalise_type()
  end

  defp normalise_type("Person"), do: "Person"
  defp normalise_type("Service"), do: "Service"
  defp normalise_type("Group"), do: "Group"
  defp normalise_type("Organization"), do: "Organization"
  defp normalise_type("Application"), do: "Application"
  defp normalise_type(_other), do: "Person"

  defp public_key(_actor_id, nil), do: nil

  defp public_key(actor_id, %Keypair{public_key: pem}) do
    %{
      "id" => Signature.key_id(actor_id),
      "owner" => actor_id,
      "publicKeyPem" => pem
    }
  end

  # Profile fields are PropertyValue attachments, which is how Mastodon has
  # always carried them and therefore how every client reads them.
  defp property_value(field) do
    %{
      "type" => "PropertyValue",
      "name" => field.name,
      "value" => field.value
    }
  end

  defp put_movement(document, %Account{} = account) do
    document
    |> maybe_put("alsoKnownAs", presence(account.also_known_as))
    |> maybe_put("movedTo", moved_to(account))
  end

  defp moved_to(%Account{moved_to_account_id: nil}), do: nil

  defp moved_to(%Account{moved_to_account_id: id}) do
    case Abuuba.Repo.get(Account, id) do
      nil -> nil
      target -> id(target)
    end
  end

  defp maybe_put(document, _key, nil), do: document
  defp maybe_put(document, key, value), do: Map.put(document, key, value)

  # A document a peer fetched declares its vocabulary; one nested inside another
  # does not, because the outer document already did. Passing `context: true`
  # is how a caller says which of the two it is building.
  defp with_context(document, opts) do
    if Keyword.get(opts, :context, false) do
      Map.put(document, "@context", JSONLD.activitystreams())
    else
      document
    end
  end

  defp presence([]), do: nil
  defp presence(nil), do: nil
  defp presence(value), do: value

  defp published(%Account{inserted_at: nil}), do: nil
  defp published(%Account{inserted_at: at}), do: DateTime.to_iso8601(at)

  # A null in an actor document is not the same as an absent key: some
  # implementations read `"movedTo": null` as a move to nowhere.
  defp reject_nils(document) do
    document
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
