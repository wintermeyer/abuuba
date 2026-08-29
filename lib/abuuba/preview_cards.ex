defmodule Abuuba.PreviewCards do
  @moduledoc """
  Turning the first link in a post into something a reader can see.

  ## oEmbed first, the page's own markup second

  A site that publishes an oEmbed document has told us how it wants to be
  embedded, which beats anything we can infer from its markup. Where there is
  none, OpenGraph tags say most of the same things, and where there are none of
  those either, the `<title>` is still more use to a reader than nothing.

  ## Never `rich`

  oEmbed's `rich` type is arbitrary HTML with no shape anybody can check, which
  is somebody else's markup running in our readers' pages. It is refused
  outright and the page's own tags are used instead. `video` embeds are kept
  but sanitised, because an iframe pointing at a video is a known shape and a
  script tag is not.

  ## The endpoint cache is what makes this fast

  Discovery costs a fetch and a parse of the site's HTML. That is a property of
  the site rather than of the article, so it is cached per host for a day,
  including the answer "this host has none". Without that second half, every
  link to a site without oEmbed pays for the discovery again on every post.

  ## Cards are keyed on where the address ended up

  Two shortened links pointing at one story are one story. Keying on what
  somebody typed would produce a card per shortener, each fetched separately
  and each wrong in its own way.

  ## Everything goes through the hardened HTTP layer

  A preview card is this server fetching a URL a stranger wrote, which is the
  textbook shape of an SSRF. `Abuuba.Federation.HTTP` is where the address
  checks, the redirect limit, the size cap and the circuit breaker live, and
  nothing here reaches around it.
  """

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.HTTP
  alias Abuuba.Federation.URIs
  alias Abuuba.PreviewCards.Card
  alias Abuuba.PreviewCards.EndpointCache
  alias Abuuba.Repo
  alias Abuuba.Statuses.Status
  alias Abuuba.Trends

  # A card believed forever is a headline that changed and a title nobody
  # updated. A fortnight is long enough that a popular link is not refetched
  # for every reader and short enough that a corrected story is picked up.
  @refresh_after_days 14

  @doc """
  The first link in a post, or `nil`.

  One card per post, and the first link is the one somebody meant. Mentions and
  hashtags are not links to unfurl however much they look like one in the
  rendered HTML.
  """
  @spec first_url(String.t() | nil) :: String.t() | nil
  def first_url(nil), do: nil

  def first_url(text) do
    text
    |> candidate_urls()
    |> Enum.find(&unfurlable?/1)
  end

  @doc """
  The card for a URL, fetching it if this server has not seen it lately.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, Card.t()} | {:error, term()}
  def fetch(url, opts \\ []) do
    case get_by_url(url) do
      %Card{} = card ->
        if stale?(card), do: refetch(card, opts), else: {:ok, card}

      nil ->
        fetch_and_store(url, opts)
    end
  end

  @doc """
  The card attached to a status, or `nil`.
  """
  @spec for_status(Status.t() | integer()) :: Card.t() | nil
  def for_status(%Status{id: id}), do: for_status(id)

  def for_status(status_id) do
    from(c in Card,
      join: j in "preview_cards_statuses",
      on: j.preview_card_id == c.id,
      where: j.status_id == ^status_id,
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  The cards for a page of statuses, keyed by status id.

  One query for the page. Asking per post is twenty queries for twenty posts,
  which is exactly what a timeline is.
  """
  @spec for_statuses([integer()]) :: %{integer() => Card.t()}
  def for_statuses([]), do: %{}

  def for_statuses(status_ids) do
    from(c in Card,
      join: j in "preview_cards_statuses",
      on: j.preview_card_id == c.id,
      where: j.status_id in ^status_ids,
      select: {j.status_id, c}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Hangs a card on a status, and counts the link towards what is trending.

  A link nobody attached to a post is a link nobody shared, which is why the
  trend is registered here rather than at the moment the card was fetched.
  """
  @spec attach(Status.t(), Card.t()) :: :ok
  def attach(%Status{} = status, %Card{} = card) do
    Repo.insert_all(
      "preview_cards_statuses",
      [[preview_card_id: card.id, status_id: status.id]],
      on_conflict: :nothing
    )

    Trends.record_link(status, card.url)

    :ok
  end

  @doc """
  Points a post at the card for the link it now carries, and at no other.

  An edit can change the link or take it away, and `attach/2` only ever adds,
  so without this a post kept the headline and the picture of a URL that was no
  longer in its text -- which is worse than having none, because a reader has
  no way to tell it is stale.

  The old row goes at once rather than when a new fetch lands: the fetch talks
  to somebody else's server and may be slow, fail, or never happen at all
  because the new text has no link in it.
  """
  @spec relink(Status.t()) :: :ok
  def relink(%Status{} = status) do
    wanted = first_url(status.text)

    keep =
      case wanted && get_by_url(wanted) do
        %Card{id: id} -> [id]
        _ -> []
      end

    from(j in "preview_cards_statuses",
      where: j.status_id == ^status.id and j.preview_card_id not in ^keep
    )
    |> Repo.delete_all()

    :ok
  end

  @doc """
  One card by its address, or `nil`.
  """
  @spec get_by_url(String.t()) :: Card.t() | nil
  def get_by_url(url), do: Repo.get_by(Card, url: url)

  @doc """
  Cards for several links at once, keyed by url. One query for a page of
  trends rather than one per trend.
  """
  @spec get_by_urls([String.t()]) :: %{String.t() => Card.t()}
  def get_by_urls([]), do: %{}

  def get_by_urls(urls) do
    Card |> where([c], c.url in ^urls) |> Repo.all() |> Map.new(&{&1.url, &1})
  end

  @doc """
  Whether a host's oEmbed situation is already known.
  """
  @spec endpoint_known?(String.t()) :: boolean()
  def endpoint_known?(host), do: EndpointCache.lookup(host) != :miss

  @doc """
  Forgets what is known about a host, as the day would have.
  """
  @spec expire_endpoint(String.t()) :: :ok
  defdelegate expire_endpoint(host), to: EndpointCache, as: :expire

  @doc "How old a card may be before it is read again."
  @spec refresh_after_days() :: pos_integer()
  def refresh_after_days, do: @refresh_after_days

  ## Finding the link

  # Bare hyperlinks in plain text, and the `href` of every anchor in rendered
  # HTML, which is how a post from another server arrives.
  defp candidate_urls(text) do
    hrefs = Regex.scan(~r/href="([^"]+)"/, text) |> Enum.map(fn [_match, url] -> url end)

    bare =
      ~r{https?://[^\s<>"']+}
      |> Regex.scan(strip_tags(text))
      |> Enum.map(fn [url] -> String.trim_trailing(url, ".") end)

    Enum.uniq(hrefs ++ bare)
  end

  # A mention and a hashtag are links in the rendered markup and are not links
  # anybody meant to share.
  defp unfurlable?(url) do
    uri = URI.parse(url)

    is_binary(uri.host) and uri.scheme in ["http", "https"] and
      not String.starts_with?(uri.path || "", "/tags/") and
      not String.starts_with?(uri.path || "", "/@")
  end

  defp strip_tags(text), do: String.replace(text, ~r/<[^>]*>/, " ")

  ## Fetching

  defp stale?(%Card{fetched_at: nil}), do: true

  defp stale?(%Card{fetched_at: fetched_at}) do
    DateTime.diff(DateTime.utc_now(), fetched_at, :day) >= @refresh_after_days
  end

  defp refetch(card, opts) do
    case read(card.url, opts) do
      {:ok, attrs} -> card |> Card.changeset(attrs) |> Repo.update()
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_and_store(url, opts) do
    with {:ok, attrs} <- read(url, opts) do
      # Keyed on where the address ended up, so a second shortener pointing at
      # the same story finds the card that already exists.
      case get_by_url(attrs.url) do
        %Card{} = existing -> existing |> Card.changeset(attrs) |> Repo.update()
        nil -> %Card{} |> Card.changeset(attrs) |> Repo.insert()
      end
    end
  end

  # The order is the optimisation. Where the host's endpoint is already known,
  # oEmbed is asked first and the page's HTML is never fetched at all, which is
  # what makes the second article from a newspaper cost one request instead of
  # two. Where it is not, the HTML comes first because that is where the
  # endpoint is discovered.
  defp read(url, opts) do
    case EndpointCache.lookup(URI.parse(url).host) do
      {:ok, %{endpoint: endpoint}} when is_binary(endpoint) ->
        read_via_known_endpoint(url, endpoint, opts)

      _ ->
        read_page(url, opts)
    end
  end

  defp read_via_known_endpoint(url, endpoint, opts) do
    case HTTP.get_document(oembed_url(endpoint, url), opts) do
      {:ok, %{body: body}} ->
        case oembed_attrs(body) do
          attrs when map_size(attrs) > 0 -> {:ok, Map.merge(bare(url), attrs)}
          _ -> read_page(url, opts)
        end

      _ ->
        # The endpoint we remembered did not answer, so fall back to reading
        # the page rather than returning nothing.
        read_page(url, opts)
    end
  end

  defp read_page(url, opts) do
    with {:ok, page} <- HTTP.get_document(url, Keyword.put(opts, :accept, HTTP.browser_accept())) do
      document = LazyHTML.from_document(page.body)

      base = from_html(document, page.url)

      {:ok, Map.merge(base, from_oembed(document, page.url, opts))}
    end
  end

  # What is known about a URL before anything has been read: enough for a card
  # that an oEmbed answer then fills in.
  defp bare(url) do
    uri = URI.parse(url)

    %{
      url: url,
      title: "",
      description: "",
      type: "link",
      provider_name: uri.host,
      provider_url: "#{uri.scheme}://#{uri.host}",
      html: "",
      width: 0,
      height: 0,
      embed_url: "",
      fetched_at: DateTime.utc_now()
    }
  end

  ## OpenGraph and the page's own tags

  defp from_html(document, url) do
    %{
      url: url,
      title: meta(document, "og:title") || meta(document, "twitter:title") || title_tag(document),
      description:
        meta(document, "og:description") || meta(document, "twitter:description") || "",
      type: "link",
      image_url: URIs.absolute(meta(document, "og:image"), url),
      image_description: meta(document, "og:image:alt"),
      provider_name: meta(document, "og:site_name") || URI.parse(url).host,
      provider_url: "#{URI.parse(url).scheme}://#{URI.parse(url).host}",
      author_name: meta(document, "article:author") || "",
      author_account_id: creator_account_id(document, url),
      html: "",
      width: 0,
      height: 0,
      embed_url: "",
      fetched_at: DateTime.utc_now()
    }
  end

  defp meta(document, property) do
    ["meta[property='#{property}']", "meta[name='#{property}']"]
    |> Enum.find_value(fn selector ->
      document |> LazyHTML.query(selector) |> LazyHTML.attribute("content") |> List.first()
    end)
    |> presence()
  end

  defp title_tag(document) do
    document |> LazyHTML.query("title") |> LazyHTML.text() |> String.trim() |> presence() || ""
  end

  # Somebody's claim about themselves in their own markup, checked twice: that
  # the account exists, and that it has agreed to be named by this site.
  # Neither check alone is worth anything -- an unresolved handle is just a
  # string, and a resolved one that never named the domain is the site
  # claiming to be somebody.
  defp creator_account_id(document, url) do
    with handle when is_binary(handle) <- meta(document, "fediverse:creator"),
         %Account{} = account <- Accounts.lookup(String.trim_leading(handle, "@")),
         true <- attributable?(account, URI.parse(url).host) do
      account.id
    else
      _not_attributable -> nil
    end
  end

  # Existing is not consent. The handle in a page's markup is written by
  # whoever runs the site, so without this any site could name anybody and be
  # credited to them -- their name and their face on a page they have never
  # seen, in front of everybody who shares the link. The account has to have
  # named the domain first.
  #
  # A named domain covers its subdomains, because that is what somebody means
  # by listing their site, and it is how `*.example.com` is written upstream.
  defp attributable?(%Account{attribution_domains: domains}, host)
       when is_binary(host) and domains != [] do
    host = String.downcase(host)

    Enum.any?(domains, fn domain ->
      host == domain or String.ends_with?(host, "." <> domain)
    end)
  end

  defp attributable?(_account, _host), do: false

  ## oEmbed

  defp from_oembed(document, url, opts) do
    host = URI.parse(url).host

    case endpoint_for(host, document, url) do
      nil ->
        %{}

      endpoint ->
        case HTTP.get_document(oembed_url(endpoint, url), opts) do
          {:ok, %{body: body}} -> oembed_attrs(body)
          _ -> %{}
        end
    end
  end

  defp endpoint_for(host, document, url) do
    case EndpointCache.lookup(host) do
      {:ok, %{endpoint: endpoint}} ->
        endpoint

      :miss ->
        endpoint = discover(document, url)

        # Remembered either way. "This host has none" is the half people
        # forget, and without it every link to such a site pays again.
        EndpointCache.put(host, endpoint)

        endpoint
    end
  end

  defp discover(document, url) do
    ["link[type='application/json+oembed']", "link[type='text/json+oembed']"]
    |> Enum.find_value(fn selector ->
      document |> LazyHTML.query(selector) |> LazyHTML.attribute("href") |> List.first()
    end)
    |> case do
      nil -> nil
      href -> URIs.absolute(href, url)
    end
  end

  # The endpoint is a template in the sense that it takes the URL as a
  # parameter; a discovered one usually carries it already.
  defp oembed_url(endpoint, url) do
    uri = URI.parse(endpoint)

    if uri.query && String.contains?(uri.query, "url=") do
      endpoint
    else
      separator = if uri.query, do: "&", else: "?"

      "#{endpoint}#{separator}url=#{URI.encode_www_form(url)}&format=json"
    end
  end

  defp oembed_attrs(body) do
    case Jason.decode(body) do
      {:ok, %{"type" => type} = document} when type in ["video", "photo", "link"] ->
        %{
          type: type,
          title: presence(document["title"]),
          author_name: document["author_name"],
          author_url: document["author_url"],
          provider_name: presence(document["provider_name"]),
          provider_url: document["provider_url"],
          width: integer(document["width"]),
          height: integer(document["height"]),
          html: sanitise_embed(type, document["html"]),
          image_url: document["thumbnail_url"]
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      # `rich` is arbitrary HTML with no shape anybody can check. The page's
      # own tags are a worse description and a far better bargain.
      _ ->
        %{}
    end
  end

  # Only a video carries an embed, and it is rebuilt rather than cleaned. A
  # sanitiser answers "is there anything dangerous in this markup", which is a
  # question about everything somebody could write; taking the one attribute an
  # embed actually needs and constructing the element ourselves answers "is
  # this the shape we allow", which is a question about one thing.
  defp sanitise_embed("video", html) when is_binary(html) do
    case embed_source(html) do
      nil -> ""
      src -> ~s(<iframe src="#{src}" frameborder="0" allowfullscreen></iframe>)
    end
  end

  defp sanitise_embed(_type, _html), do: ""

  defp embed_source(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("iframe")
    |> LazyHTML.attribute("src")
    |> List.first()
    |> case do
      src when is_binary(src) -> if https?(src), do: escape(src)
      _ -> nil
    end
  end

  # https only. An embed served over plain HTTP inside a page served over TLS
  # is blocked by every browser anyway, and asking for it tells the reader's
  # network what they are watching.
  defp https?(src), do: URI.parse(src).scheme == "https"

  defp escape(src), do: String.replace(src, ~s("), "%22")

  ## Plumbing

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      _ -> nil
    end
  end

  defp integer(_value), do: nil

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: value
  defp presence(_value), do: nil
end
