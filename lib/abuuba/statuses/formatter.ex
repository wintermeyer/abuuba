defmodule Abuuba.Statuses.Formatter do
  @moduledoc """
  Turning what somebody typed into what everybody else reads.

  ## One pipeline, two consumers

  The compose box's preview and the document that federates both come from
  here. That is the point of it being a module rather than a template helper: a
  preview that linkified differently from the post would show somebody a
  mention that then failed to reach anybody, and they would have no way to tell
  before pressing send.

  ## Escaping happens first

  The text is escaped before anything is linked, and the links are built from
  the escaped text. Doing it the other way round means an author can write
  markup that survives into everybody's timeline, which is the oldest bug in
  this kind of software.

  ## What is recognised

  Mentions as `@name` or `@name@host`, hashtags as `#word`, and custom emoji as
  `:shortcode:`. Nothing else: this is not Markdown, because the fediverse
  renders plain text with links and anything richer would be shown to most
  readers as literal asterisks.
  """

  alias Abuuba.Accounts
  alias Abuuba.Federation.URIs
  alias Abuuba.Instance
  alias Abuuba.Statuses.Tag

  # A mention is a handle, so the same characters a username may contain and
  # the same domains WebFinger accepts.
  @mention ~r/(?<![\w\/])@([a-zA-Z0-9_]+)(?:@([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}))?/
  # `\p{L}\p{N}` rather than the POSIX classes, which stay ASCII-only even with
  # the unicode flag and would refuse #Grüße and #日本語.
  # The same shape `Abuuba.Statuses.Tag` validates, separators and all. The two
  # have to agree: a tag this extracts and the schema then refuses is a link
  # to nothing, and one the schema allows but this never finds is a hashtag
  # that only works when somebody else's server sent it.
  @hashtag_separators "_\u00B7\u30FB\u200C"
  @hashtag ~r/(?<![\w&])#((?=[\p{L}\p{N}#{@hashtag_separators}]*[\p{L}_])[\p{L}\p{N}_](?:[\p{L}\p{N}#{@hashtag_separators}]*[\p{L}\p{N}_])?)/u
  @shortcode ~r/:([a-zA-Z0-9_]+):/
  # Deliberately narrow: a scheme and then anything that is not whitespace or a
  # character HTML would have escaped. Trailing punctuation is trimmed off
  # afterwards, because a link at the end of a sentence is followed by a full
  # stop that is not part of it.
  @url ~r{https?://[^\s<>"']+}
  # What a URL counts as, whatever its length. Upstream's number, and every
  # client draws its counter to match: a link is 23 to the person composing,
  # so it has to be 23 to the server refusing.
  @url_length 23
  # What every link carries, whoever wrote the post. `noopener` matters because
  # the links open in a new tab; `nofollow` because a post is not an
  # endorsement; `noreferrer` because the page somebody came from is nobody
  # else's business.
  @link_rel "nofollow noopener noreferrer"

  @doc """
  The HTML a reader sees.
  """
  @spec to_html(String.t() | nil, keyword()) :: String.t()
  def to_html(text, opts \\ [])

  def to_html(nil, _opts), do: ""

  def to_html(text, opts) do
    text
    |> escape()
    |> link_urls()
    # Applied between the anchors rather than across the whole string. A URL is
    # linked first, and a mention or a hashtag pass running over the result
    # would otherwise match inside the `href` it just wrote -- `#tag` in
    # `https://example.com/#tag`, or the `/tags/tag` of a hashtag already
    # linked.
    |> outside_anchors(&link_mentions(&1, accounts(text, opts)))
    |> outside_anchors(&link_hashtags/1)
    |> render_emoji(opts)
    |> paragraphs()
  end

  # A link somebody typed, made clickable. Without this a URL in a post is text
  # every reader has to select and paste, while the hashtag beside it is a
  # link.
  defp link_urls(text) do
    Regex.replace(@url, text, fn match ->
      {url, trailing} = split_trailing_punctuation(match)

      ~s(<a href="#{attr(url)}" rel="#{@link_rel}" target="_blank">#{url}</a>) <> trailing
    end)
  end

  # A link at the end of a sentence is followed by a full stop that is not part
  # of it, and one written inside brackets by a closing bracket that is not
  # either. A bracket is only given back when it is unbalanced, though:
  # `…/Elixir_(programming_language)` ends in a bracket that belongs to the
  # address, and cutting it off links to a 404.
  defp split_trailing_punctuation(url), do: split_trailing_punctuation(url, "")

  defp split_trailing_punctuation(url, trailing) do
    case String.last(url) do
      nil ->
        {url, trailing}

      last when last in [".", ",", ";", ":", "!", "?"] ->
        split_trailing_punctuation(String.slice(url, 0..-2//1), last <> trailing)

      last when last in [")", "]"] ->
        if unbalanced?(url, last) do
          split_trailing_punctuation(String.slice(url, 0..-2//1), last <> trailing)
        else
          {url, trailing}
        end

      _kept ->
        {url, trailing}
    end
  end

  # More closing brackets than opening ones, so the last of them was never part
  # of the address: somebody wrote the link inside brackets of their own.
  defp unbalanced?(url, closing) do
    opening = if closing == ")", do: "(", else: "["

    count(url, opening) < count(url, closing)
  end

  defp count(string, character) do
    string |> String.graphemes() |> Enum.count(&(&1 == character))
  end

  # Splits on anchors and applies `fun` only to what lies between them, so a
  # pass cannot rewrite the inside of a link another pass has already made.
  defp outside_anchors(html, fun) do
    ~r{<a\b[^>]*>.*?</a>}s
    |> Regex.split(html, include_captures: true)
    |> Enum.map_join(fn part ->
      if String.starts_with?(part, "<a"), do: part, else: fun.(part)
    end)
  end

  @doc """
  Another server's HTML, with everything dangerous taken out.

  Applied where a remote post is stored rather than where it is rendered, so
  that there is one place the cleaning happens and no renderer has to remember
  to do it. The allow-list is a library's rather than ours: a hand-rolled one
  is the classic way to ship a hole.
  """
  @spec sanitize(String.t() | nil) :: String.t()
  def sanitize(nil), do: ""

  def sanitize(html) when is_binary(html) do
    html
    |> HtmlSanitizeEx.basic_html()
    |> mark_links()
  end

  @doc """
  An account's bio, as markup that is safe to render.

  Ours is plain text and is escaped on the way out; theirs is markup that was
  cleaned on the way in. Both go through this, so neither is ever rendered as
  the other — and it is one function rather than two copies, because it was
  two, and only one of them carried the sentence above.

  Matches on the shape rather than on `%Account{}` so that this module does not
  have to know the schema: it is already what resolves mentions through
  `Abuuba.Accounts`, and depending on the struct as well would close the loop.
  """
  @spec note_html(%{optional(:domain) => String.t() | nil, note: String.t() | nil}) :: String.t()
  def note_html(%{domain: nil, note: note}), do: to_html(note)
  def note_html(%{note: note}), do: sanitize(note)

  @doc """
  What a post says, with the markup taken off.

  The other direction from `to_html/2`, and here beside it for that reason: a
  summary line, a meta description, an RSS blurb and an admin listing all want
  the words and none of them want the tags. It was written out separately in
  eight places under four names, each with its own length baked in, which is
  how a tag-stripping regex comes to be fixed in one of them.

  `:limit` cuts the result to that many characters; without it the whole text
  comes back.
  """
  @spec plain_text(String.t() | nil, keyword()) :: String.t()
  def plain_text(html, opts \\ []) do
    text =
      html
      |> to_string()
      |> String.replace(~r/<[^>]*>/, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    case Keyword.get(opts, :limit) do
      nil -> text
      limit -> String.slice(text, 0, limit)
    end
  end

  # The sanitiser takes `rel` and `target` off along with everything else it
  # does not recognise, and puts nothing back. Upstream's adds both to every
  # anchor it keeps, and since local posts got them a link in the same timeline
  # opened in a new tab or the same one depending on which server wrote it.
  #
  # Applied to the sanitised markup, so an attribute cannot arrive from the
  # other server: whatever was there has already been stripped, and this is the
  # only thing that writes one.
  defp mark_links(html) do
    Regex.replace(~r/<a\b([^>]*)>/, html, fn _whole, attributes ->
      "<a" <> attributes <> ~s( rel="#{@link_rel}" target="_blank">)
    end)
  end

  @doc """
  Who a post addresses, as handles.

  Returned rather than resolved, because resolving means fetching an actor from
  another server and that is a different concern with its own failure modes.
  """
  @spec mentions(String.t() | nil) :: [String.t()]
  def mentions(nil), do: []

  def mentions(text) do
    @mention
    |> Regex.scan(text)
    |> Enum.map(fn
      [_whole, name] -> name
      [_whole, name, domain] -> "#{name}@#{domain}"
    end)
    |> Enum.uniq()
  end

  @doc """
  Which tags a post files itself under, casefolded.
  """
  @spec hashtags(String.t() | nil) :: [String.t()]
  def hashtags(nil), do: []

  def hashtags(text) do
    @hashtag
    |> Regex.scan(text)
    |> Enum.map(fn [_whole, name] -> Tag.normalise(name) end)
    |> Enum.uniq()
  end

  @doc """
  Which custom emoji a post uses.
  """
  @spec shortcodes(String.t() | nil) :: [String.t()]
  def shortcodes(nil), do: []

  def shortcodes(text) do
    @shortcode
    |> Regex.scan(text)
    |> Enum.map(fn [_whole, code] -> code end)
    |> Enum.uniq()
  end

  @doc """
  How long a post is, as the counter counts it.

  A mention of somebody on another server counts as the local part alone, which
  is what the reference implementation does: charging somebody for the length
  of a domain they did not choose would make a conversation with people on long
  domains impossible.
  """
  @spec length(String.t() | nil) :: non_neg_integer()
  def length(nil), do: 0

  def length(text) do
    text
    |> String.replace(@url, String.duplicate("x", @url_length))
    |> String.replace(@mention, fn match ->
      match |> String.split("@") |> Enum.take(2) |> Enum.join("@")
    end)
    |> String.length()
  end

  @doc """
  What a URL counts as, whatever its length.
  """
  @spec url_length() :: pos_integer()
  def url_length, do: @url_length

  # Escaped before anything is linked, and the links are built from the escaped
  # text. The other order lets an author write markup that survives into
  # everybody's timeline.
  defp escape(text), do: Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()

  defp link_mentions(text, accounts) do
    Regex.replace(@mention, text, fn whole, name, domain ->
      handle = if domain == "", do: name, else: "#{name}@#{domain}"

      case Map.get(accounts, handle) do
        nil -> whole
        url -> ~s(<a href="#{attr(url)}" class="mention" rel="nofollow noopener">@#{name}</a>)
      end
    end)
  end

  defp link_hashtags(text) do
    Regex.replace(@hashtag, text, fn _whole, name ->
      ~s(<a href="#{base_url()}/tags/#{Tag.normalise(name)}" class="hashtag" rel="tag">##{name}</a>)
    end)
  end

  # A shortcode nobody has an image for is left as typed. Somebody writing
  # ":shrug:" meant the word, and turning it into a broken image would be a
  # worse guess than leaving it alone.
  defp render_emoji(text, opts) do
    emojis = Keyword.get_lazy(opts, :emojis, &emoji_index/0)

    Regex.replace(@shortcode, text, fn whole, code ->
      case Map.get(emojis, code) do
        nil -> whole
        url -> ~s(<img src="#{attr(url)}" alt=":#{code}:" title=":#{code}:" class="emoji" />)
      end
    end)
  end

  # Blank lines become paragraphs and single newlines become breaks, which is
  # how everybody writes in a plain-text box and what every other server sends.
  defp paragraphs(text) do
    text
    |> String.split(~r/\R{2,}/)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map_join("", fn paragraph ->
      "<p>" <> String.replace(paragraph, ~r/\R/, "<br />") <> "</p>"
    end)
  end

  # Resolved once for the whole text rather than once per occurrence: somebody
  # answering a crowded thread names the same people repeatedly, and each name
  # is a lookup.
  defp accounts(text, opts) do
    case Keyword.get(opts, :accounts) do
      nil -> text |> mentions() |> Enum.flat_map(&resolve/1) |> Map.new()
      accounts -> accounts
    end
  end

  defp resolve(handle) do
    case Accounts.lookup(handle) do
      nil -> []
      account -> [{handle, URIs.profile_url(account)}]
    end
  end

  defp emoji_index do
    Map.new(Instance.custom_emojis(), &{&1.shortcode, &1.image_url})
  end

  # Every address here comes from a row somebody else wrote: an emoji picture
  # fetched from another server, a profile URL from a remote actor document.
  # Interpolated as typed, a quote in one of them ends the attribute and starts
  # an attribute of the author's choosing.
  defp attr(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  defp base_url, do: URIs.base_url()
end
