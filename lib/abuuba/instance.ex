defmodule Abuuba.Instance do
  @moduledoc """
  What this server says about itself.

  Two audiences read it and they want different things. Crawlers and the
  fediverse-statistics sites read NodeInfo, which is a small standard document
  every server implements. Client apps read `/api/v2/instance`, which tells
  them the limits to enforce in their own compose box before a post is refused.

  Both are honest about the software name. Claiming to be Mastodon would make
  bug reports about abuuba land in Mastodon's tracker, and it would make abuuba
  invisible in the statistics that decide whether anybody tries it.
  """

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.LoginActivity
  alias Abuuba.Accounts.User
  alias Abuuba.Cache
  alias Abuuba.Federation.URIs
  alias Abuuba.Instance.Announcement
  alias Abuuba.Instance.CustomEmoji
  alias Abuuba.Instance.EmojiImages
  alias Abuuba.Instance.TermsOfService
  alias Abuuba.Media.Attachment
  alias Abuuba.Media.Pipeline
  alias Abuuba.Media.Upload
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Settings
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.Status
  alias Abuuba.Streaming

  @software_name "abuuba"

  # The client API level abuuba implements, which is what apps feature-detect on.
  # Distinct from the version above: an app cares which endpoints exist, not
  # which server is answering them.
  @mastodon_api_compatibility "4.3.0"

  @max_characters 500
  @max_media_attachments 4
  @characters_reserved_per_url 23

  @doc """
  The software version, taken from the mix project so it cannot drift.
  """
  @spec version() :: String.t()
  def version, do: Application.spec(:abuuba, :vsn) |> to_string()

  @doc """
  How long a post may be.

  Read rather than hardcoded at each caller, so the composer's counter and the
  changeset that rejects the post cannot disagree — a counter that says there
  is room left while the save fails is the worst of both.
  """
  @spec max_characters() :: pos_integer()
  def max_characters, do: @max_characters

  @doc """
  How many attachments one post may carry.
  """
  @spec max_media_attachments() :: pos_integer()
  def max_media_attachments, do: @max_media_attachments

  @doc """
  The software name. Honest on purpose; see the module doc.
  """
  @spec software_name() :: String.t()
  def software_name, do: @software_name

  @doc """
  The NodeInfo discovery document, which points at the real one.
  """
  @spec well_known_nodeinfo() :: map()
  def well_known_nodeinfo do
    %{
      "links" => [
        %{
          "rel" => "http://nodeinfo.diaspora.software/ns/schema/2.0",
          "href" => "#{URIs.base_url()}/nodeinfo/2.0"
        }
      ]
    }
  end

  @doc """
  NodeInfo 2.0.
  """
  @spec nodeinfo() :: map()
  def nodeinfo do
    usage = usage()

    %{
      "version" => "2.0",
      "software" => %{"name" => @software_name, "version" => version()},
      "protocols" => ["activitypub"],
      "services" => %{"outbound" => [], "inbound" => []},
      "usage" => %{
        "users" => %{
          "total" => usage.users,
          "activeMonth" => usage.active_month,
          "activeHalfyear" => usage.active_halfyear
        },
        "localPosts" => usage.statuses
      },
      "openRegistrations" => Settings.registration_mode() == :open,
      "metadata" => %{
        "nodeName" => Settings.get("site_title"),
        "nodeDescription" => Settings.get("site_description") || ""
      }
    }
  end

  @doc """
  The `/api/v2/instance` payload.

  The `configuration` block is the part that matters most: a client reads it to
  enforce the same limits in its own compose box, so somebody finds out their
  post is too long while they are writing it rather than when they press send.
  """
  @spec instance_v2() :: map()
  def instance_v2 do
    # `usage/0` is served from the cache, so `instance_v1/0` asking again a
    # moment later costs an ETS read, not a recount.
    usage = usage()

    %{
      "domain" => URIs.local_domain(),
      "title" => Settings.get("site_title"),
      "version" => "#{@mastodon_api_compatibility} (compatible; #{@software_name} #{version()})",
      "source_url" => "https://github.com/wintermeyer/abuuba",
      "description" => Settings.get("site_description") || "",
      "usage" => %{"users" => %{"active_month" => usage.active_month}},
      "thumbnail" => %{"url" => "#{URIs.base_url()}/images/thumbnail.png"},
      "languages" => Abuuba.I18n.known_locales(),
      "configuration" => configuration(),
      "registrations" => registrations(),
      "api_versions" => %{"mastodon" => 5},
      "contact" => contact(),
      "rules" => rules()
    }
  end

  @doc """
  The `/api/v1/instance` payload.

  Deprecated upstream and kept anyway, because plenty of installed clients
  still ask for it and would show an empty instance rather than an error.
  """
  @spec instance_v1() :: map()
  def instance_v1 do
    v2 = instance_v2()
    usage = usage()

    %{
      "uri" => URIs.local_domain(),
      "title" => v2["title"],
      "short_description" => v2["description"],
      "description" => v2["description"],
      "email" => contact_email(),
      "version" => v2["version"],
      # A string here, where v2 nests it under an object of its own.
      "thumbnail" => v2["thumbnail"]["url"],
      "urls" => %{"streaming_api" => streaming_url()},
      "stats" => %{
        "user_count" => usage.users,
        "status_count" => usage.statuses,
        "domain_count" => usage.domains
      },
      "languages" => v2["languages"],
      "registrations" => Settings.registration_open?(),
      "approval_required" => Settings.registration_mode() == :approved,
      # Server-wide rather than about the reader: a client shows or hides its
      # invite screen from this before anybody has signed in.
      "invites_enabled" => Roles.everyone_can?("invite_users"),
      "contact_account" => v2["contact"]["account"],
      "configuration" => v2["configuration"],
      "rules" => v2["rules"]
    }
  end

  # Null where there are none, which is what the reference implementation sends
  # and what stops a client putting a "terms of service" link on a blank page.
  defp terms_of_service_url do
    if current_terms(), do: "#{URIs.base_url()}/terms"
  end

  @doc """
  The limits a client should enforce before it lets somebody press send.
  """
  @spec configuration() :: map()
  def configuration do
    %{
      "urls" => %{
        "streaming" => streaming_url(),
        # The pages a client links to rather than renders itself. `about` and
        # `privacy_policy` always exist; terms are null until somebody writes
        # them, because a link to a page that says nothing is worse than none.
        "about" => "#{URIs.base_url()}/about",
        "privacy_policy" => "#{URIs.base_url()}/privacy",
        "terms_of_service" => terms_of_service_url(),
        # Wherever an operator says what is broken and when it will be back.
        # Null unless one has been named, which is what a client reads to
        # decide whether to offer the link at all.
        "status" => presence(Settings.get("site_status_page_url"))
      },
      "vapid" => %{"public_key" => Application.get_env(:abuuba, :vapid_public_key)},
      "accounts" => %{
        "max_featured_tags" => Statuses.featured_tags_max(),
        "max_pinned_statuses" => Statuses.max_pins()
      },
      "statuses" => %{
        "max_characters" => max_characters(),
        "max_media_attachments" => max_media_attachments(),
        # A URL counts as this many characters however long it is, so that a
        # long link does not eat somebody's whole post.
        "characters_reserved_per_url" => @characters_reserved_per_url
      },
      "media_attachments" => %{
        "supported_mime_types" =>
          ~w(image/jpeg image/png image/gif image/webp video/mp4 audio/mpeg),
        "image_size_limit" => Upload.max_bytes(:image),
        "image_matrix_limit" => Pipeline.Image.max_pixels(),
        "video_size_limit" => Upload.max_bytes(:video),
        "video_frame_rate_limit" => 120,
        "video_matrix_limit" => 8_294_400,
        # What a client sizes its alt-text box to.
        "description_limit" => Attachment.max_description()
      },
      # Read from what the server enforces rather than written out again here.
      # The longest poll was a literal six times shorter than what is actually
      # accepted, so a client offering the longest poll it had been told about
      # withheld five months of it.
      "polls" => %{
        "max_options" => Poll.max_options(),
        "max_characters_per_option" => Poll.max_option_characters(),
        "min_expiration" => Poll.min_expiration_seconds(),
        "max_expiration" => Poll.max_expiration_seconds()
      },
      "translation" => %{"enabled" => Abuuba.Translation.enabled?()}
    }
  end

  defp registrations do
    %{
      "enabled" => Settings.registration_open?(),
      "approval_required" => Settings.registration_mode() == :approved,
      # The key the admin screen writes. It read `registration_message`, which
      # nothing sets, so the note an admin wrote for somebody turned away at
      # the door was never shown to them.
      "message" => Settings.get("closed_registration_message"),
      "min_age" => nil
    }
  end

  defp contact do
    %{
      "email" => contact_email(),
      # Upstream lets an admin name an account here as well as an address.
      # There is no setting for that on this server yet, and null is what
      # upstream sends when nobody has named one.
      "account" => nil
    }
  end

  # `site_contact_email` is what the admin screen writes and what
  # `Abuuba.Admin.put_settings/2` allows; this read `contact_email`, which
  # nothing writes, so the one address for reaching whoever runs the server
  # answered empty however carefully it had been filled in.
  defp contact_email, do: Settings.get("site_contact_email") || ""

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp presence(_value), do: nil

  @doc """
  The local account an admin has named as the one to write to, or `nil`.

  A username rather than an id, because that is what an admin knows and what
  survives somebody rebuilding a database from an export. A name that belongs
  to nobody here answers `nil` rather than an error: a typo in a settings box
  should leave the line off a client's screen, not break the endpoint every
  client reads at startup.
  """
  @spec contact_account() :: Account.t() | nil
  def contact_account do
    case Settings.get("site_contact_account") do
      name when is_binary(name) and name != "" -> Accounts.get_account_by_handle(name, nil)
      _unset -> nil
    end
  end

  defp rules do
    Settings.rules(Gettext.get_locale(AbuubaWeb.Gettext))
    |> Enum.with_index(1)
    |> Enum.map(fn {rule, index} ->
      %{"id" => to_string(index), "text" => rule.text, "hint" => rule.hint}
    end)
  end

  @doc """
  The numbers this server can honestly report about itself.

  The same ones the instance document carries, so the about page and the API
  cannot disagree about how many people are here. Cached for a few minutes:
  every client asks for the instance document on startup, the counts scan the
  two largest tables, and nobody reads them to the second.
  """
  @spec usage() :: map()
  def usage do
    Cache.fetch(:instance_usage, :timer.minutes(5), fn ->
      %{
        users: Repo.aggregate(User, :count),
        statuses: local_status_count(),
        domains: known_domain_count(),
        active_month: active_since(30),
        active_halfyear: active_since(180)
      }
    end)
  end

  @activity_weeks 12

  @doc """
  Twelve weeks of this server's own pulse: posts written, people signing in,
  people joining. Newest week first, every value a string, because that is
  what the reference implementation sends and what the crawlers parse.

  Posts and registrations are counted from their own tables, which keep the
  history. Sign-ins cannot be: `login_activities` is swept after 30 days
  because it records where people were, so each completed week's
  distinct-user count is frozen into `weekly_logins` -- a number per week,
  nothing about who -- before the sweep takes the rows it came from. The
  freeze takes the greater of the stored and computed counts, so a week
  half-eaten by the sweep can never lower a number that was already right.
  """
  @spec activity() :: [map()]
  def activity do
    Cache.fetch(:instance_activity, :timer.hours(24), fn ->
      monday = Date.beginning_of_week(Date.utc_today())
      weeks = for n <- 0..(@activity_weeks - 1), do: Date.add(monday, -7 * n)
      oldest = weeks |> List.last() |> DateTime.new!(~T[00:00:00])

      statuses = per_week(Status, oldest, where: [local: true])
      registrations = per_week(User, oldest, [])
      logins = frozen_logins(weeks)

      Enum.map(weeks, fn week ->
        %{
          "week" =>
            week |> DateTime.new!(~T[00:00:00]) |> DateTime.to_unix() |> Integer.to_string(),
          "statuses" => Integer.to_string(Map.get(statuses, week, 0)),
          "logins" => Integer.to_string(Map.get(logins, week, 0)),
          "registrations" => Integer.to_string(Map.get(registrations, week, 0))
        }
      end)
    end)
  end

  defp per_week(schema, oldest, opts) do
    schema
    |> where([r], r.inserted_at >= ^oldest)
    |> then(fn q ->
      case Keyword.get(opts, :where) do
        [local: true] -> where(q, [r], r.local == true and is_nil(r.deleted_at))
        _none -> q
      end
    end)
    |> group_by([r], fragment("date_trunc('week', ?)", r.inserted_at))
    |> select([r], {fragment("date_trunc('week', ?)::date", r.inserted_at), count(r.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp frozen_logins(weeks) do
    oldest = weeks |> List.last() |> DateTime.new!(~T[00:00:00])

    computed =
      LoginActivity
      |> where([l], l.success == true and l.inserted_at >= ^oldest)
      |> group_by([l], fragment("date_trunc('week', ?)", l.inserted_at))
      |> select(
        [l],
        {fragment("date_trunc('week', ?)::date", l.inserted_at), count(l.user_id, :distinct)}
      )
      |> Repo.all()

    freeze(computed)

    from(w in "weekly_logins",
      where: w.week_start in ^weeks,
      select: {w.week_start, w.count}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp freeze([]), do: :ok

  defp freeze(computed) do
    rows = Enum.map(computed, fn {week, count} -> [week_start: week, count: count] end)

    keep_greater =
      from(w in "weekly_logins",
        update: [set: [count: fragment("GREATEST(EXCLUDED.count, ?)", w.count)]]
      )

    Repo.insert_all("weekly_logins", rows,
      on_conflict: keep_greater,
      conflict_target: [:week_start]
    )

    :ok
  end

  defp local_status_count do
    Status
    |> where([s], s.local == true and is_nil(s.deleted_at))
    |> Repo.aggregate(:count)
  end

  # `count(distinct)` in the database rather than shipping every distinct
  # value to the node to measure the list.
  defp known_domain_count do
    Account
    |> where([a], not is_nil(a.domain))
    |> select([a], count(a.domain, :distinct))
    |> Repo.one()
  end

  # "Active" means posted, which is the only signal we have without tracking
  # when somebody merely read something. Undercounts lurkers on purpose rather
  # than logging reading habits to make a statistic look better.
  defp active_since(days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    Status
    |> where([s], s.local == true and s.inserted_at > ^cutoff)
    |> select([s], count(s.account_id, :distinct))
    |> Repo.one()
  end

  defp streaming_url do
    "#{if URIs.scheme() == "https", do: "wss", else: "ws"}://#{URIs.local_domain()}/api/v1/streaming"
  end

  ## Custom emoji

  @doc """
  Every emoji a client should offer in its picker.

  Local and enabled only. A picker full of another server's emoji would let
  somebody type a name that renders here and nowhere else, since the picture
  travels with the post only if the sending server has it.

  This is the set that *renders*, so it includes the ones an admin has taken
  out of the picker: a name already written into a post keeps its picture.
  `offered_custom_emojis/0` is the shorter list a composer chooses from.
  """
  @spec custom_emojis() :: [CustomEmoji.t()]
  def custom_emojis do
    # Read through the cache: the composer's preview and the federation
    # serializer ask for this list per render, and it changes when an admin
    # uploads an emoji, which is to say almost never.
    Cache.fetch(:custom_emojis, :timer.minutes(5), fn ->
      CustomEmoji
      |> where([e], is_nil(e.domain) and not e.disabled)
      |> order_by([e], asc: e.shortcode)
      |> Repo.all()
    end)
  end

  @doc """
  The ones a composer may pick from, which is a shorter list than the ones that
  render.

  An emoji taken out of the picker keeps working in every post that already
  uses it -- that is the whole difference between unoffering one and turning it
  off, and it is why this is a second list rather than a narrower `custom_emojis/0`.
  """
  @spec offered_custom_emojis() :: [CustomEmoji.t()]
  def offered_custom_emojis do
    Enum.filter(custom_emojis(), & &1.visible_in_picker)
  end

  @doc """
  Every emoji this server knows, its own first, for an admin looking at them.
  """
  @spec all_custom_emojis() :: [CustomEmoji.t()]
  def all_custom_emojis do
    CustomEmoji
    |> order_by([e], asc: e.domain, asc: e.shortcode)
    |> Repo.all()
  end

  @doc """
  What this server's own emoji of that name currently points at, or `nil`.

  Read before a replacement is stored, so the file the new picture displaces
  can be deleted once the new one is safely written.
  """
  @spec local_emoji_image_url(String.t() | nil) :: String.t() | nil
  def local_emoji_image_url(shortcode) when is_binary(shortcode) do
    CustomEmoji
    |> where([e], e.shortcode == ^shortcode and is_nil(e.domain))
    |> select([e], e.image_url)
    |> Repo.one()
  end

  def local_emoji_image_url(_shortcode), do: nil

  @doc """
  Adds one of this server's own, or replaces the one already using the name.

  One shortcode is one picture here: a second row with the same name is a name
  the picker cannot choose between. Another server's `:blobcat:` is a different
  row and is left alone — theirs is what their posts render with.
  """
  @spec put_local_emoji(map()) :: {:ok, CustomEmoji.t()} | {:error, Ecto.Changeset.t()}
  def put_local_emoji(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    existing =
      case attrs["shortcode"] do
        shortcode when is_binary(shortcode) ->
          # `is_nil` rather than `domain: nil`: Ecto refuses the second, and
          # "the local one" is exactly what a null domain means here.
          CustomEmoji
          |> where([e], e.shortcode == ^shortcode and is_nil(e.domain))
          |> Repo.one()

        _missing ->
          nil
      end

    changeset = CustomEmoji.changeset(existing || %CustomEmoji{}, attrs)

    with {:ok, emoji} <- Repo.insert_or_update(changeset) do
      Cache.invalidate(:custom_emojis)

      {:ok, emoji}
    end
  end

  @doc """
  Turns one of this server's own on or off.

  Off means off: the shortcode stops rendering, so every post that used it
  shows the bare `:name:` until somebody turns it back on. Disabled rather
  than deleted, so that turning it back on restores all of them at once, and
  `set_custom_emoji_offered/2` is the gentler thing an admin usually wants.
  """
  @spec set_custom_emoji_disabled(CustomEmoji.t(), boolean()) ::
          {:ok, CustomEmoji.t()} | {:error, Ecto.Changeset.t()}
  def set_custom_emoji_disabled(%CustomEmoji{} = emoji, disabled?) do
    with {:ok, updated} <-
           emoji |> CustomEmoji.changeset(%{"disabled" => disabled?}) |> Repo.update() do
      Cache.invalidate(:custom_emojis)

      {:ok, updated}
    end
  end

  @doc """
  Takes one out of the picker, or puts it back.

  The quiet half of the pair. The picture keeps working in every post that
  already carries the shortcode; it is only no longer offered for new ones,
  which is what an admin retiring a name almost always means.
  """
  @spec set_custom_emoji_offered(CustomEmoji.t(), boolean()) ::
          {:ok, CustomEmoji.t()} | {:error, Ecto.Changeset.t()}
  def set_custom_emoji_offered(%CustomEmoji{} = emoji, offered?) do
    with {:ok, updated} <-
           emoji |> CustomEmoji.changeset(%{"visible_in_picker" => offered?}) |> Repo.update() do
      Cache.invalidate(:custom_emojis)

      {:ok, updated}
    end
  end

  @doc """
  Removes one, and the picture behind it where this server was holding it.
  """
  @spec delete_custom_emoji(CustomEmoji.t()) :: :ok
  def delete_custom_emoji(%CustomEmoji{} = emoji) do
    EmojiImages.discard(emoji)
    Repo.delete(emoji)
    Cache.invalidate(:custom_emojis)

    :ok
  end

  @doc """
  Records an emoji, local or from another server.
  """
  @spec put_custom_emoji(map()) :: {:ok, CustomEmoji.t()} | {:error, Ecto.Changeset.t()}
  def put_custom_emoji(attrs) do
    with {:ok, emoji} <- %CustomEmoji{} |> CustomEmoji.changeset(attrs) |> Repo.insert() do
      Cache.invalidate(:custom_emojis)

      {:ok, emoji}
    end
  end

  @doc """
  Records the custom emoji another server used, from the `tag` array of a post
  or an actor document.

  Kept per domain and never merged with ours. `:blobcat:` on their server and
  `:blobcat:` on ours are two different pictures with the same name, and
  rendering theirs with our image would put a picture in somebody's post that
  they never chose.

  The URL is refreshed when it changes, because an emoji re-uploaded on the
  other end keeps its shortcode and gets a new address; storing the first one
  forever would leave a broken image in every post that used it.

  Returns the shortcodes it knows about afterwards, so a caller can tell
  whether anything was worth storing without asking again.
  """
  @spec put_remote_emoji([map()] | nil, String.t() | nil) :: [String.t()]
  def put_remote_emoji(tags, domain) when is_list(tags) and is_binary(domain) and domain != "" do
    tags
    |> Enum.flat_map(&remote_emoji_attrs(&1, domain))
    |> Enum.map(&upsert_remote_emoji/1)
    |> Enum.reject(&is_nil/1)
  end

  def put_remote_emoji(_tags, _domain), do: []

  @doc """
  The emoji one server has used here, by shortcode.

  Read per render for a remote post or profile that actually uses a shortcode,
  which is a minority of them; the caller checks first.
  """
  @spec remote_emoji(String.t() | nil) :: %{String.t() => CustomEmoji.t()}
  def remote_emoji(domain) when is_binary(domain) and domain != "" do
    CustomEmoji
    |> where([e], e.domain == ^domain and not e.disabled)
    |> Repo.all()
    |> Map.new(&{&1.shortcode, &1})
  end

  def remote_emoji(_domain), do: %{}

  # Only what an ActivityStreams `Emoji` tag is: a name between colons and an
  # icon with a URL. Anything else in `tag` is a mention or a hashtag and is
  # somebody else's business.
  defp remote_emoji_attrs(%{"type" => "Emoji", "name" => name} = tag, domain)
       when is_binary(name) do
    with shortcode when shortcode != "" <- String.trim(name, ":"),
         url when is_binary(url) <- icon_url(tag) do
      [%{shortcode: shortcode, domain: domain, image_url: url, static_url: url}]
    else
      _ -> []
    end
  end

  defp remote_emoji_attrs(_tag, _domain), do: []

  defp icon_url(%{"icon" => %{"url" => url}}) when is_binary(url), do: url
  defp icon_url(_tag), do: nil

  # The shortcode and domain together are the key, which is what the unique
  # index on `(shortcode, coalesce(domain, ''))` already says.
  defp upsert_remote_emoji(attrs) do
    now = DateTime.utc_now()

    row = [
      shortcode: attrs.shortcode,
      domain: attrs.domain,
      image_url: attrs.image_url,
      static_url: attrs.static_url,
      visible_in_picker: false,
      inserted_at: now,
      updated_at: now
    ]

    Repo.insert_all(CustomEmoji, [row],
      conflict_target: {:unsafe_fragment, "(shortcode, coalesce(domain, ''))"},
      on_conflict: [
        set: [image_url: attrs.image_url, static_url: attrs.static_url, updated_at: now]
      ]
    )

    attrs.shortcode
  rescue
    # An emoji that could not be stored is a shortcode rendered as text, which
    # is what happened before this existed. It is not a reason to drop a post.
    _error -> nil
  end

  ## Terms of service

  @doc """
  Publishes a version of the terms.

  A new row each time. See `Abuuba.Instance.TermsOfService` for why the text is
  never edited in place.
  """
  @spec publish_terms(Account.t(), map()) ::
          {:ok, TermsOfService.t()} | {:error, Ecto.Changeset.t()}
  def publish_terms(%Account{} = actor, attrs) do
    attrs = Map.put(normalise_keys(attrs), "published_at", DateTime.utc_now())

    with {:ok, terms} <- %TermsOfService{} |> TermsOfService.changeset(attrs) |> Repo.insert() do
      AuditLog.record(actor, "terms.publish", :terms, terms.id, %{
        "effective_date" => to_string(terms.effective_date),
        "label" => "terms of #{terms.effective_date}"
      })

      {:ok, terms}
    end
  end

  @doc """
  The version in force today, or `nil` on a server that never wrote any.

  A version published with a future date is deliberately not this one:
  publishing the next version early is how people get told before it applies,
  which is the whole point of an effective date.
  """
  @spec current_terms(Date.t()) :: TermsOfService.t() | nil
  def current_terms(today \\ Date.utc_today()) do
    TermsOfService
    |> where([t], not is_nil(t.published_at) and t.effective_date <= ^today)
    |> order_by([t], desc: t.effective_date)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  The version that took effect on a given day.
  """
  @spec terms_for(Date.t()) :: TermsOfService.t() | nil
  def terms_for(date), do: Repo.get_by(TermsOfService, effective_date: date)

  @doc """
  Every version, newest first.
  """
  @spec terms_versions(map()) :: [TermsOfService.t()]
  def terms_versions(page \\ %{}) do
    TermsOfService
    |> order_by([t], desc: t.effective_date)
    |> limit(^Map.get(page, :limit, 50))
    |> Repo.all()
  end

  @doc """
  Tells everybody about a new version.

  One announcement rather than a notification each: there is no mail yet, and a
  row per account for something everybody reads in the same place would be a
  hundred thousand rows saying one thing. Once only, because an announcement
  written twice is an announcement people stop reading.
  """
  @spec announce_terms(TermsOfService.t()) ::
          {:ok, TermsOfService.t()} | {:error, :already_announced}
  def announce_terms(%TermsOfService{notified_at: nil} = terms) do
    {:ok, _announcement} =
      create_announcement(%{
        text:
          "The terms of service change on #{terms.effective_date}. You can read them at /terms.",
        published: true
      })

    terms
    |> TermsOfService.changeset(%{notified_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def announce_terms(%TermsOfService{}), do: {:error, :already_announced}

  # Attributes arrive as atoms from our own code and as strings from a form.
  defp normalise_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  ## Announcements

  @doc """
  What everybody should be reading right now.
  """
  @spec announcements(DateTime.t()) :: [Announcement.t()]
  def announcements(now \\ DateTime.utc_now()) do
    Announcement
    |> where([a], a.published)
    |> order_by([a], desc: a.id)
    |> Repo.all()
    |> Enum.filter(&Announcement.current?(&1, now))
  end

  @doc """
  Every announcement, published or not, newest first. For the admin area.
  """
  @spec all_announcements(map()) :: [Announcement.t()]
  def all_announcements(page \\ %{}) do
    Announcement
    |> order_by([a], desc: a.id)
    |> limit(^Map.get(page, :limit, 50))
    |> Repo.all()
  end

  @doc """
  Takes an announcement down.
  """
  @spec delete_announcement(Announcement.t()) ::
          {:ok, Announcement.t()} | {:error, Ecto.Changeset.t()}
  def delete_announcement(%Announcement{} = announcement), do: Repo.delete(announcement)

  @doc """
  One announcement.
  """
  @spec get_announcement(integer() | nil) :: Announcement.t() | nil
  def get_announcement(nil), do: nil
  def get_announcement(id), do: Repo.get(Announcement, id)

  @doc """
  Creates one.
  """
  @spec create_announcement(map()) :: {:ok, Announcement.t()} | {:error, Ecto.Changeset.t()}
  def create_announcement(attrs) do
    %Announcement{} |> Announcement.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Records that somebody has read one.
  """
  @spec dismiss_announcement(Announcement.t(), Account.t() | integer()) :: :ok
  def dismiss_announcement(announcement, %Account{id: id}),
    do: dismiss_announcement(announcement, id)

  def dismiss_announcement(%Announcement{id: announcement_id}, account_id) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "announcement_dismissals",
      [
        %{
          announcement_id: announcement_id,
          account_id: account_id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:announcement_id, :account_id]
    )

    :ok
  end

  @doc """
  Whether somebody has read one.
  """
  @spec announcement_read?(Announcement.t(), Account.t() | integer() | nil) :: boolean()
  def announcement_read?(_announcement, nil), do: false

  def announcement_read?(announcement, %Account{id: id}),
    do: announcement_read?(announcement, id)

  def announcement_read?(%Announcement{id: announcement_id}, account_id) do
    from(d in "announcement_dismissals",
      where: d.announcement_id == ^announcement_id and d.account_id == ^account_id
    )
    |> Repo.exists?()
  end

  @doc """
  Reacts to one, or takes a reaction back.
  """
  @spec react_to_announcement(Announcement.t(), Account.t() | integer(), String.t()) :: :ok
  def react_to_announcement(announcement, %Account{id: id}, name),
    do: react_to_announcement(announcement, id, name)

  def react_to_announcement(%Announcement{id: announcement_id}, account_id, name) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "announcement_reactions",
      [
        %{
          announcement_id: announcement_id,
          account_id: account_id,
          name: name,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:announcement_id, :account_id, :name]
    )

    announce_reaction(announcement_id, name)
  end

  @doc """
  Takes a reaction back.
  """
  @spec unreact_to_announcement(Announcement.t(), Account.t() | integer(), String.t()) :: :ok
  def unreact_to_announcement(announcement, %Account{id: id}, name),
    do: unreact_to_announcement(announcement, id, name)

  def unreact_to_announcement(%Announcement{id: announcement_id}, account_id, name) do
    from(r in "announcement_reactions",
      where:
        r.announcement_id == ^announcement_id and r.account_id == ^account_id and r.name == ^name
    )
    |> Repo.delete_all()

    announce_reaction(announcement_id, name)
  end

  # The new count, to everybody signed in. A client draws the tally under a
  # notice and had no way to learn that it moved -- so two people reacting to
  # the same announcement each saw only their own.
  #
  # Sent for a reaction taken back as well, where the count may now be zero:
  # that is how a client knows to remove the button rather than leave one
  # reading "1" that nobody stands behind.
  defp announce_reaction(announcement_id, name) do
    count =
      from(r in "announcement_reactions",
        where: r.announcement_id == ^announcement_id and r.name == ^name,
        select: count(r.account_id)
      )
      |> Repo.one()

    Streaming.publish_announcement_reaction(announcement_id, name, count || 0)
  end

  @doc """
  How many people reacted with each emoji, and whether this reader is one.
  """
  @spec announcement_reactions(Announcement.t(), Account.t() | integer() | nil) :: [map()]
  def announcement_reactions(announcement, viewer \\ nil)

  def announcement_reactions(%Announcement{id: announcement_id}, viewer) do
    viewer_id = viewer_id(viewer)

    from(r in "announcement_reactions",
      where: r.announcement_id == ^announcement_id,
      group_by: r.name,
      select: {r.name, count(r.account_id), fragment("bool_or(? = ?)", r.account_id, ^viewer_id)}
    )
    |> Repo.all()
    |> Enum.map(fn {name, count, me?} -> %{name: name, count: count, me: me? || false} end)
    |> Enum.sort_by(& &1.name)
  end

  defp viewer_id(%Account{id: id}), do: id
  defp viewer_id(id) when is_integer(id), do: id
  defp viewer_id(_viewer), do: -1

  ## Peers

  @doc """
  Every server this one has heard from.

  Names only, which is all the endpoint promises. It is a map of who talks to
  whom, and publishing anything more about a peer than that it exists would
  say something about our own users' reach that they did not agree to.
  """
  @spec peers() :: [String.t()]
  def peers do
    from(a in Account,
      where: not is_nil(a.domain),
      distinct: true,
      select: a.domain,
      order_by: a.domain
    )
    |> Repo.all()
  end

  @doc """
  The peers whose name starts with what somebody typed.

  For a completion box rather than for browsing, so it is a prefix match and a
  short list. An empty query answers with nothing rather than with every server
  this instance has ever heard of: a box that fills itself before anybody types
  is not a completion box.
  """
  @spec peers_starting_with(String.t() | nil, keyword()) :: [String.t()]
  def peers_starting_with(query, opts \\ [])
  def peers_starting_with(query, _opts) when query in [nil, ""], do: []

  def peers_starting_with(query, opts) do
    prefix = query |> to_string() |> String.trim() |> String.downcase()

    if prefix == "" do
      []
    else
      from(a in Account,
        where: not is_nil(a.domain) and like(a.domain, ^(escape_like(prefix) <> "%")),
        distinct: true,
        select: a.domain,
        order_by: a.domain,
        limit: ^Keyword.get(opts, :limit, 10)
      )
      |> Repo.all()
    end
  end

  # `%` and `_` are wildcards in LIKE, so a domain somebody typed with one in
  # it would match far more than they asked for.
  defp escape_like(value) do
    String.replace(value, ~r/([\\%_])/, "\\\\\\1")
  end
end
