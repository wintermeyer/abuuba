defmodule Abuuba.Federation.JSONLD do
  @moduledoc """
  The `@context` abuuba emits, and the document shapes it refuses to read.

  ActivityPub is JSON-LD, and JSON-LD is a graph format that can express the
  same document in a great many equivalent ways. Nothing on the fediverse
  treats it that way in practice: every implementation reads
  `document["object"]["content"]` out of a plain map, and every implementation
  writes a `@context` assembled by hand from a list it maintains. Doing real
  JSON-LD expansion on the way in would be correct and would also mean
  understanding documents no peer can produce and no peer can read back.

  So this module does the pragmatic thing, deliberately:

  * **Outbound**, a `@context` built from named contexts plus the extension
    terms a particular document actually uses. Emitting the full union on every
    document would be simpler and would put a hundred lines of vocabulary on
    every post.
  * **Inbound**, plain map access, plus a refusal to read documents that use
    the JSON-LD constructions plain map access would misread.

  ## Why refuse rather than ignore

  A document whose real content sits under `@graph` reads, through plain map
  access, as an empty document. Acting on what is left is the bad outcome: a
  `Delete` whose target is hidden in a construction we skipped is a `Delete` of
  nothing, and an attacker choosing the construction chooses what we see. There
  is no legitimate traffic in these shapes, so refusing costs nothing.
  """

  # Full URLs, in the order a consumer has to read them.
  @named %{
    activitystreams: "https://www.w3.org/ns/activitystreams",
    security: "https://w3id.org/security/v1"
  }

  @activitystreams @named.activitystreams

  @public "https://www.w3.org/ns/activitystreams#Public"

  # Prefixes the terms below are written against. Defined once per document
  # however many terms need them.
  @prefixes %{
    "toot" => "http://joinmastodon.org/ns#",
    "schema" => "http://schema.org#",
    # Older than the rest and still what threading is written against.
    "ostatus" => "http://ostatus.org#"
  }

  # One entry per extension term a serializer may ask for. Kept as data rather
  # than as one blob so that a document carries the vocabulary it uses and not
  # the vocabulary anything else uses.
  @terms %{
    blurhash: %{"blurhash" => "toot:blurhash"},
    conversation: %{"conversation" => "ostatus:conversation"},
    discoverable: %{"discoverable" => "toot:discoverable"},
    emoji: %{"Emoji" => "toot:Emoji"},
    featured: %{"featured" => %{"@id" => "toot:featured", "@type" => "@id"}},
    # A pair of numbers, so the order is part of the meaning.
    focal_point: %{"focalPoint" => %{"@container" => "@list", "@id" => "toot:focalPoint"}},
    hashtag: %{"Hashtag" => "as:Hashtag"},
    indexable: %{"indexable" => "toot:indexable"},
    manually_approves_followers: %{"manuallyApprovesFollowers" => "as:manuallyApprovesFollowers"},
    memorial: %{"memorial" => "toot:memorial"},
    # A set rather than a list: the order of somebody's own domains means
    # nothing, and saying so keeps a peer from reading it as one.
    attribution_domains: %{
      "attributionDomains" => %{"@id" => "toot:attributionDomains", "@container" => "@set"}
    },
    property_value: %{"PropertyValue" => "schema:PropertyValue", "value" => "schema:value"},
    quote: %{
      "quote" => %{"@id" => "https://w3id.org/fep/044f#quote", "@type" => "@id"},
      "quoteAuthorization" => %{
        "@id" => "https://w3id.org/fep/044f#quoteAuthorization",
        "@type" => "@id"
      },
      "quoteUri" => %{"@id" => "http://fedibird.com/ns#quoteUri", "@type" => "@id"},
      "_misskey_quote" => %{
        "@id" => "https://misskey-hub.net/ns#_misskey_quote",
        "@type" => "@id"
      }
    },
    quote_authorization: %{
      "QuoteAuthorization" => "https://w3id.org/fep/044f#QuoteAuthorization",
      "interactingObject" => %{
        "@id" => "https://w3id.org/fep/044f#interactingObject",
        "@type" => "@id"
      },
      "interactionTarget" => %{
        "@id" => "https://w3id.org/fep/044f#interactionTarget",
        "@type" => "@id"
      }
    },
    interaction_policy: %{
      "gts" => "https://gotosocial.org/ns#",
      "interactionPolicy" => %{"@id" => "gts:interactionPolicy", "@type" => "@id"},
      "canLike" => %{"@id" => "gts:canLike", "@type" => "@id"},
      "canReply" => %{"@id" => "gts:canReply", "@type" => "@id"},
      "canAnnounce" => %{"@id" => "gts:canAnnounce", "@type" => "@id"},
      "canQuote" => %{"@id" => "gts:canQuote", "@type" => "@id"},
      "always" => %{"@id" => "gts:always", "@type" => "@id"},
      "approvalRequired" => %{"@id" => "gts:approvalRequired", "@type" => "@id"},
      "automaticApproval" => %{"@id" => "gts:automaticApproval", "@type" => "@id"},
      "manualApproval" => %{"@id" => "gts:manualApproval", "@type" => "@id"}
    },
    sensitive: %{"sensitive" => "as:sensitive"},
    voters_count: %{"votersCount" => "toot:votersCount"}
  }

  # Which prefix each term is written against, so a document defines `toot`
  # only when something in it says `toot:`.
  @prefix_for %{
    blurhash: "toot",
    conversation: "ostatus",
    discoverable: "toot",
    emoji: "toot",
    featured: "toot",
    focal_point: "toot",
    attribution_domains: "toot",
    indexable: "toot",
    memorial: "toot",
    property_value: "schema",
    voters_count: "toot"
  }

  # Deep enough for any real document; a peer that nests further than this is
  # not describing a post.
  @max_depth 40

  @doc """
  The `@context` for a document using these extension terms.

  With no terms this is the ActivityStreams namespace as a bare string, which
  is what the network sends for a plain object and what a strict consumer
  expects to see.
  """
  @spec context([atom()]) :: String.t() | [String.t() | map()]
  def context(terms \\ [])
  def context([]), do: @activitystreams

  def context(terms) do
    {named, extensions} = Enum.split_with(terms, &Map.has_key?(@named, &1))

    case vocabulary(extensions) do
      empty when map_size(empty) == 0 -> named_contexts(named)
      vocabulary -> named_contexts(named) ++ [vocabulary]
    end
  end

  @doc """
  Whether a document uses a JSON-LD construction that plain map access would
  misread.

  Checked all the way down, because the nesting is the dangerous case: a
  document whose top level looks ordinary and whose meaning hides in a
  construction we skipped is exactly the document worth refusing.
  """
  @spec foreign_shape?(term()) :: boolean()
  def foreign_shape?(document), do: foreign_shape?(document, 0)

  # Too deep to finish checking, so it is refused. Whatever this is, it is not
  # a post, and "we could not tell" has to mean "no".
  defp foreign_shape?(_document, depth) when depth > @max_depth, do: true

  defp foreign_shape?(document, depth) when is_map(document) do
    is_map_key(document, "@graph") or is_map_key(document, "@included") or
      is_map_key(document, "@reverse") or
      Enum.any?(Map.values(document), &foreign_shape?(&1, depth + 1))
  end

  defp foreign_shape?(document, depth) when is_list(document) do
    Enum.any?(document, &foreign_shape?(&1, depth + 1))
  end

  defp foreign_shape?(_document, _depth), do: false

  @doc """
  The ActivityStreams namespace, for documents that name it directly.
  """
  @spec activitystreams() :: String.t()
  def activitystreams, do: @activitystreams

  @doc """
  The collection that means "everybody".

  Addressing it is the whole of what "public" means on the wire, both ways: it
  is how we say a post is public and how we read that a peer's is. One
  definition, because a typo in a second copy would make posts public in one
  direction and not the other.
  """
  @spec public() :: String.t()
  def public, do: @public

  defp named_contexts(named) do
    [@activitystreams | Enum.map(named, &Map.fetch!(@named, &1))]
  end

  defp vocabulary(extensions) do
    Enum.reduce(extensions, %{}, fn term, acc ->
      case Map.fetch(@terms, term) do
        {:ok, definition} -> acc |> Map.merge(definition) |> put_prefix(term)
        # A context that names a term nothing defines is a context that lies
        # about what the document means.
        :error -> raise ArgumentError, "no JSON-LD term defined for #{inspect(term)}"
      end
    end)
  end

  defp put_prefix(vocabulary, term) do
    case Map.fetch(@prefix_for, term) do
      {:ok, prefix} -> Map.put(vocabulary, prefix, Map.fetch!(@prefixes, prefix))
      :error -> vocabulary
    end
  end
end
