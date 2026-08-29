defmodule Abuuba.Translation do
  @moduledoc """
  Asking somebody else what a post says in another language.

  ## Off unless a server sets it up

  A translate button nobody configured is a button that answers every press
  with an error. Nothing is offered until a provider and its credentials are
  there.

  ## One call, not five

  The content, the content warning, the poll options and the media
  descriptions go in a single request. Providers bill per request as well as
  per character, and five round trips is five chances to be rate limited on a
  post somebody is waiting to read.

  ## Custom emoji are marked as not to be translated

  A provider handed `:blobcat:` will translate it into something that is no
  longer a shortcode and no longer renders. Wrapping each one in a
  `translate="no"` span is what both DeepL and LibreTranslate honour when the
  text is sent as HTML.

  ## Only what anybody may read

  Translating means handing the words to a third party. A followers-only post
  is not ours to hand over, however much the person reading it would like it
  translated.

  ## Cached for a day, keyed on the words

  These calls are metered. A hundred readers asking for one post is one call.
  The key is a hash of what was actually sent plus the language pair, so two
  posts with the same text are one translation and an edited post is a new one
  without anything having to remember to invalidate it.
  """

  import Ecto.Query

  alias Abuuba.Media.Attachment
  alias Abuuba.Repo
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.Status

  @typedoc "What a provider gives back for one post."
  @type t :: %{
          content: String.t(),
          spoiler_text: String.t(),
          detected_source_language: String.t() | nil,
          provider: String.t(),
          poll: map() | nil,
          media_attachments: [map()]
        }

  @doc "Translates a batch of texts."
  @callback translate([String.t()], String.t() | nil, String.t(), keyword()) ::
              {:ok, [String.t()]} | {:error, atom()}

  @doc "Which languages the provider can translate between."
  @callback languages(keyword()) :: {:ok, %{String.t() => [String.t()]}} | {:error, atom()}

  @doc "What the provider is called, for the API to report."
  @callback name() :: String.t()

  @cache_hours 24
  @languages_days 7
  @languages_key "languages"

  @doc """
  Whether this server can translate anything at all.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: provider() != nil

  @doc """
  Which provider is in force, or `nil`.
  """
  @spec provider() :: module() | nil
  def provider, do: Application.get_env(:abuuba, :translation_provider)

  @doc """
  What the provider is called, or `nil`.
  """
  @spec provider_name() :: String.t() | nil
  def provider_name do
    case provider() do
      nil -> nil
      module -> module.name()
    end
  end

  @doc """
  Which languages can be translated into which, cached for a week.

  The list is a property of the provider's account and changes about never, so
  asking on every page load would be a request bought for nothing.
  """
  @spec languages() :: %{String.t() => [String.t()]}
  def languages do
    case provider() do
      nil -> %{}
      module -> cached_languages(module)
    end
  end

  defp cached_languages(module) do
    case cached(@languages_key) do
      {:ok, languages} -> languages
      :miss -> ask_languages(module)
    end
  end

  defp ask_languages(module) do
    case module.languages([]) do
      {:ok, languages} ->
        put(@languages_key, languages, @languages_days * 24)

        languages

      # Not cached. A provider that was briefly unreachable should not leave
      # this server claiming it can translate nothing for a week.
      _ ->
        %{}
    end
  end

  @doc """
  Translates one post.
  """
  @spec translate(Status.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def translate(%Status{} = status, target) do
    target = normalise(target)

    with :ok <- check_enabled(),
         :ok <- check_translatable(status, target) do
      parts = parts(status)
      key = cache_key(parts, status.language, target)

      case cached(key) do
        {:ok, value} -> {:ok, rebuild(value, status)}
        :miss -> fetch(status, parts, key, target)
      end
    end
  end

  @doc """
  Whether a post may be translated at all.

  Public and unlisted only, and never into the language it is already in.
  """
  @spec translatable?(Status.t(), String.t()) :: boolean()
  def translatable?(%Status{} = status, target) do
    check_translatable(status, normalise(target)) == :ok
  end

  @doc """
  Empties the cache. For a server that has changed provider, and for tests.
  """
  @spec expire_all() :: :ok
  def expire_all do
    Repo.delete_all("translation_cache")

    :ok
  end

  @doc """
  Removes entries whose day has passed.
  """
  @spec sweep() :: :ok
  def sweep do
    now = DateTime.utc_now()

    Repo.delete_all(from(c in "translation_cache", where: c.expires_at <= ^now))

    :ok
  end

  ## Inside

  defp check_enabled do
    if enabled?(), do: :ok, else: {:error, :not_configured}
  end

  defp check_translatable(%Status{visibility: visibility}, _target)
       when visibility not in [:public, :unlisted],
       do: {:error, :not_translatable}

  defp check_translatable(%Status{language: language}, target) do
    if normalise(language) == target, do: {:error, :same_language}, else: :ok
  end

  # The order matters and is repeated on the way back, so a provider that
  # returns a list in the order it was given lands each string where it came
  # from. Nothing here relies on the provider knowing what any of them are.
  defp parts(%Status{} = status) do
    poll = poll_of(status)
    attachments = attachments_of(status)

    %{
      content: protect_emoji(status.text || ""),
      spoiler_text: protect_emoji(status.spoiler_text || ""),
      poll_options: Enum.map(poll_options(poll), &protect_emoji/1),
      poll_id: poll && poll.id,
      media: Enum.map(attachments, &%{id: &1.id, description: &1.description || ""})
    }
  end

  defp texts(parts) do
    [parts.content, parts.spoiler_text] ++
      parts.poll_options ++ Enum.map(parts.media, & &1.description)
  end

  defp fetch(status, parts, key, target) do
    module = provider()
    originals = texts(parts)

    case module.translate(Enum.reject(originals, &(&1 == "")), status.language, target, []) do
      {:ok, translated} ->
        value =
          parts
          |> assemble(restore(originals, translated), status.language, module.name())

        put(key, value, @cache_hours)

        {:ok, rebuild(value, status)}

      # Never cached. A minute of being throttled would otherwise become a day
      # of a button that does nothing.
      {:error, reason} ->
        {:error, reason}
    end
  end

  # An empty part is not sent: a provider handed an empty string bills for the
  # request and answers with whatever its prefix happens to be, which then
  # shows up as a content warning nobody wrote. Walking the originals is what
  # puts each answer back where it came from.
  defp restore(originals, translated) do
    {restored, _rest} =
      Enum.map_reduce(originals, translated, fn
        "", rest -> {"", rest}
        _text, [head | rest] -> {head, rest}
        text, [] -> {text, []}
      end)

    restored
  end

  defp assemble(parts, translated, source, provider_name) do
    # The wrapper exists for the provider's benefit. Left in, it renders as
    # escaped markup in the middle of somebody's post.
    translated = Enum.map(translated, &unprotect_emoji/1)

    {content, rest} = List.pop_at(translated, 0)
    {spoiler, rest} = List.pop_at(rest, 0)

    {poll_options, media} = Enum.split(rest, length(parts.poll_options))

    %{
      "content" => content || "",
      "spoiler_text" => spoiler || "",
      "poll_options" => poll_options,
      "poll_id" => parts.poll_id,
      "media" =>
        parts.media
        |> Enum.zip(media)
        |> Enum.map(fn {attachment, description} ->
          %{"id" => to_string(attachment.id), "description" => description}
        end),
      "detected_source_language" => source,
      "provider" => provider_name
    }
  end

  # Rebuilt from the cached value each time rather than stored as an entity, so
  # a change to how a translation is shaped does not have to invalidate a day
  # of somebody's cache.
  defp rebuild(value, status) do
    %{
      content: Statuses.content_html(%{status | text: value["content"]}),
      spoiler_text: value["spoiler_text"],
      detected_source_language: value["detected_source_language"],
      provider: value["provider"],
      poll: rebuilt_poll(value),
      media_attachments:
        Enum.map(value["media"] || [], &%{id: &1["id"], description: &1["description"]})
    }
  end

  defp rebuilt_poll(%{"poll_id" => nil}), do: nil

  defp rebuilt_poll(%{"poll_id" => id, "poll_options" => options}) do
    %{id: to_string(id), options: Enum.map(options, &%{title: &1})}
  end

  defp rebuilt_poll(_value), do: nil

  defp poll_of(%Status{} = status), do: Repo.get_by(Poll, status_id: status.id)

  defp poll_options(nil), do: []
  defp poll_options(%Poll{options: options}), do: options || []

  defp attachments_of(%Status{} = status) do
    Attachment
    |> where([a], a.status_id == ^status.id)
    |> order_by([a], asc: a.id)
    |> Repo.all()
  end

  # `translate="no"` is what both providers honour, and it only works when the
  # text is sent as HTML, which is why both adapters say so.
  defp protect_emoji(""), do: ""

  defp protect_emoji(text) do
    Regex.replace(~r/:([a-zA-Z0-9_]+):/, text, ~s(<span translate="no">:\\1:</span>))
  end

  defp unprotect_emoji(text) do
    Regex.replace(~r|<span translate="no">(:[a-zA-Z0-9_]+:)</span>|, text, "\\1")
  end

  ## The cache

  defp cache_key(parts, source, target) do
    digest =
      parts
      |> texts()
      |> Enum.join("\n")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "#{digest}:#{normalise(source)}:#{target}"
  end

  defp cached(key) do
    now = DateTime.utc_now()

    from(c in "translation_cache",
      where: c.key == ^key and c.expires_at > ^now,
      select: c.value
    )
    |> Repo.one()
    |> case do
      nil -> :miss
      value -> {:ok, value}
    end
  end

  defp put(key, value, hours) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, hours, :hour)

    Repo.insert_all(
      "translation_cache",
      [[key: key, value: value, expires_at: expires_at, inserted_at: now, updated_at: now]],
      conflict_target: [:key],
      on_conflict:
        from(c in "translation_cache",
          update: [set: [value: ^value, expires_at: ^expires_at, updated_at: ^now]]
        )
    )

    :ok
  end

  defp normalise(nil), do: nil

  # `de-DE` and `de` are the same request as far as anybody asking is
  # concerned, and a provider told the long one may answer that it cannot.
  defp normalise(language) do
    language |> to_string() |> String.downcase() |> String.split("-") |> hd()
  end
end
