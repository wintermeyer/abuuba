defmodule AbuubaWeb.API.Entities do
  @moduledoc """
  The JSON shapes the client API answers with.

  Separate from `Abuuba.Federation.Serializer`, which builds the JSON other
  *servers* read. The two describe the same posts and are not the same
  documents: one is ActivityPub, addressed to a machine that will store and
  forward it, and this one is a rendering for an app, carrying counts, the
  reader's own relationship to each post, and nothing about delivery.

  ## Every id is a string

  See `AbuubaWeb.API`. A 64-bit snowflake parsed as a JSON number loses its low
  bits in a JavaScript client, at which point two different posts compare
  equal.

  ## The reader is an argument, never a default

  Whether a post is favourited, bookmarked, muted or pinned is a fact about the
  reader rather than about the post, so every function that can answer it takes
  the reader explicitly. Rendering without one gives the anonymous view, which
  is the safe direction: the alternative is a shape that quietly leaks one
  person's bookmarks into another's timeline.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.PostingDefaults
  alias Abuuba.Accounts.User
  alias Abuuba.AsyncRefreshes.AsyncRefresh
  alias Abuuba.Collections
  alias Abuuba.Collections.Collection
  alias Abuuba.Collections.Item, as: CollectionItem
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Quotes
  alias Abuuba.Federation.Serializer
  alias Abuuba.Federation.URIs
  alias Abuuba.Filters
  alias Abuuba.Filters.Filter
  alias Abuuba.Filters.Keyword, as: FilterKeyword
  alias Abuuba.Instance
  alias Abuuba.Instance.Announcement
  alias Abuuba.Instance.CustomEmoji
  alias Abuuba.Invites.Invite
  alias Abuuba.Lists.List, as: AccountList
  alias Abuuba.Media.Attachment
  alias Abuuba.Media.ProfileImages
  alias Abuuba.Media.Upload
  alias Abuuba.Notifications.Notification
  alias Abuuba.Notifications.Policy
  alias Abuuba.Notifications.Request
  alias Abuuba.OAuth.Application
  alias Abuuba.PreviewCards
  alias Abuuba.Repo
  alias Abuuba.Roles.Role
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Bookmark
  alias Abuuba.Statuses.ConversationMute
  alias Abuuba.Statuses.Favourite
  alias Abuuba.Statuses.Formatter
  alias Abuuba.Statuses.Mention
  alias Abuuba.Statuses.Pin
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.ScheduledStatus
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.Tag
  alias Abuuba.Trends
  alias Abuuba.WebPush.Subscription
  alias Abuuba.WebPush.VAPID
  alias AbuubaWeb.API

  # An account nothing has happened to yet. `accounts_with_stats/1` coalesces
  # the missing row away, so this is only for an account that was not in the
  # batch at all.
  @zero_counters %{followers: 0, following: 0, statuses: 0, last_status: nil}

  @zero_counts %{replies: 0, reblogs: 0, favourites: 0, quotes: 0}

  # Which branch of a batched union a row came from. The tag is an integer
  # because it is emitted as a literal on every row of the query.
  @interaction_fields %{0 => :favourited, 1 => :bookmarked, 2 => :pinned, 3 => :reblogged}

  @no_interactions %{
    favourited: MapSet.new(),
    bookmarked: MapSet.new(),
    pinned: MapSet.new(),
    reblogged: MapSet.new()
  }

  @doc """
  A post, as a client renders it.
  """
  @spec status(Status.t(), Account.t() | nil) :: map()
  def status(%Status{} = status, viewer \\ nil, opts \\ []) do
    render(status, viewer, gather([status], viewer, opts))
  end

  # A moderator who marked an account covers everything it posts, before and
  # after the decision. The author is the exception: their own copy stays as
  # they wrote it, so the mark is never silently baked into an edit, and they
  # are not told through a checkbox what a moderator decided about them.
  defp sensitive?(%Status{sensitive: true}, _account, _viewer), do: true
  defp sensitive?(_status, %Account{sensitized_at: nil}, _viewer), do: false
  defp sensitive?(%Status{account_id: id}, _account, %Account{id: id}), do: false
  defp sensitive?(_status, %Account{}, _viewer), do: true
  defp sensitive?(_status, _account, _viewer), do: false

  defp render(%Status{} = status, viewer, context) do
    account = Map.get(context.accounts, status.account_id) || account_of(status)
    boosted = boosted(status, viewer, context)
    counts = Map.get(context.counts, status.id, @zero_counts)
    mentions = Map.get(context.mentions, status.id, [])

    %{
      "id" => API.id(status.id),
      "created_at" => timestamp(status.inserted_at),
      "in_reply_to_id" => API.id(status.in_reply_to_id),
      "in_reply_to_account_id" => API.id(status.in_reply_to_account_id),
      "sensitive" => sensitive?(status, account, viewer),
      "spoiler_text" => status.spoiler_text || "",
      "visibility" => to_string(status.visibility),
      "language" => status.language,
      "uri" => Serializer.status_uri(status, account),
      "url" => web_url(status, account),
      "replies_count" => counts.replies,
      "reblogs_count" => counts.reblogs,
      "favourites_count" => counts.favourites,
      "quotes_count" => counts.quotes,
      "edited_at" => timestamp(status.edited_at),
      # A boost carries no words of its own; everything a reader sees comes
      # from what it points at.
      "content" => if(boosted, do: "", else: content_html(status, mentions, context)),
      "reblog" => boosted,
      "account" =>
        Map.get(context.rendered_accounts, status.account_id) || account(account, viewer),
      "media_attachments" => Map.get(context.media, status.id, []),
      "mentions" => mentions,
      "tags" => Map.get(context.tags, status.id, []),
      "emojis" => emojis_used(status, context),
      "card" => Map.get(context.cards, status.id),
      # Only an approved quote is rendered as one. An unapproved quote is
      # somebody asserting an endorsement they were not given, so it comes back
      # as a plain post and a client shows it as one.
      "quote" => quote_entity(status, viewer, context),
      "quote_approval" => quote_approval(status),
      "poll" => context_poll(Map.get(context.polls, status.id), viewer, context),
      "application" => application_of(status, viewer, context),
      # Lists of people who write about one of this post's hashtags. A footnote
      # under the post rather than a section, so it is capped and it is only
      # ever lists their owners left discoverable.
      "tagged_collections" => tagged_collections(status, context)
    }
    |> Map.merge(reader_state(status, viewer, context))
    |> merge_filtered(status, viewer, context)
  end

  # The quoted post, rendered as any other post is, so a client needs no second
  # request to show it. Depth is not a worry: a quote of a quote renders the
  # inner one without its own quote, because this is only ever one level deep.
  # Read out of the page's own gathered quotes rather than asked for per post.
  # A page of twenty is one query for all of them; asked per post it was
  # twenty, and the budget test above is what says so.
  defp quote_entity(%Status{id: id}, viewer, context) do
    case Map.get(context.quotes, id) do
      nil ->
        nil

      %{status: %Status{} = quoted} ->
        %{"state" => "accepted", "quoted_status" => status(quoted, viewer)}

      %{status: nil} ->
        # Approved, but we do not hold the post itself. Saying so is more
        # useful to a client than pretending there is no quote.
        %{"state" => "accepted", "quoted_status" => nil}
    end
  end

  # What the reader may do with this post, which is the author's setting rather
  # than anything about the reader.
  defp quote_approval(%Status{quote_policy: policy}) do
    %{"automatic" => automatic_quote_policy(policy), "manual" => []}
  end

  defp automatic_quote_policy(:public), do: ["public"]
  defp automatic_quote_policy(:followers), do: ["followers"]
  defp automatic_quote_policy(_policy), do: []

  @doc """
  Several posts at once.

  Everything each post needs is fetched once for the whole page rather than
  once per post. A timeline renders twenty at a time and each on its own costs
  about eight queries, so the difference is a handful against a hundred and
  sixty per request.

  `:filter_context` says where these posts are being shown — `"home"`,
  `"public"`, `"thread"`, `"account"` or `"notifications"`. Given one, each
  post carries which of the reader's own filters matched it; without one the
  key is absent, because a filter applies in some places and not others and
  the wrong answer would have a client folding away posts nobody asked it to.
  """
  @spec statuses([Status.t()], Account.t() | nil, keyword()) :: [map()]
  def statuses(statuses, viewer \\ nil, opts \\ [])
  def statuses([], _viewer, _opts), do: []

  def statuses(statuses, viewer, opts) do
    context = gather(statuses, viewer, opts)

    Enum.map(statuses, &render(&1, viewer, context))
  end

  @doc """
  An account, as a client renders it.
  """
  @spec account(Account.t() | nil, Account.t() | nil) :: map() | nil
  def account(account, viewer \\ nil)
  def account(nil, _viewer), do: nil

  def account(%Account{} = account, viewer) do
    case accounts([account], viewer) do
      [rendered] -> rendered
      [] -> nil
    end
  end

  @doc """
  Several accounts at once.

  The counters come back with the accounts in one query instead of one query
  per account, which is the difference between a page of forty followers
  costing one round trip and costing forty. `account/2` is this with a list of
  one, so there is a single path rather than a batch path that only timelines
  ever reach.
  """
  @spec accounts([Account.t()], Account.t() | nil) :: [map()]
  def accounts(accounts, viewer \\ nil)
  def accounts([], _viewer), do: []

  def accounts(accounts, viewer) do
    counters =
      accounts
      |> Enum.map(& &1.id)
      |> accounts_with_stats()
      |> Map.new(fn {account, counters} -> {account.id, counters} end)

    emoji = emoji_tables(accounts)
    moved = moved_targets(accounts, viewer)

    Enum.map(accounts, fn account ->
      rendered_account(
        account,
        viewer,
        Map.get(counters, account.id, @zero_counters),
        emoji,
        moved
      )
    end)
  end

  # Where the accounts on this page have moved to, rendered once for the page.
  # One query, and only when somebody has actually moved, which is rare enough
  # that most pages never ask.
  #
  # The moved-to account is rendered without a `moved` of its own, so a chain
  # of migrations is one hop deep rather than a document that unrolls somebody
  # else's whole history. The reference implementation stops at the same place.
  defp moved_targets(accounts, viewer) do
    ids =
      accounts
      |> Enum.map(& &1.moved_to_account_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      targets = accounts_with_stats(ids)
      emoji = emoji_tables(Enum.map(targets, fn {account, _c} -> account end))

      Map.new(targets, fn {account, counters} ->
        {account.id, rendered_account(account, viewer, counters, emoji)}
      end)
    end
  end

  # The two places a shortcode can appear on a profile.
  # A display name reading `alice :blobcat:` renders the picture rather than
  # the shortcode, whoever's server it is. Which picture comes from
  # `emoji_tables/1`, keyed on the account's own domain: ours from ours and
  # theirs from theirs, never crossed.
  defp emoji_texts(%Account{} = account) do
    [account.display_name || "", account.note || ""]
  end

  # One query for the page, and only when something on it actually uses a
  # shortcode. Most pages do not, and this is read on every account rendered.
  # One table per domain on the page, built only for the domains whose accounts
  # actually use a shortcode. Most pages use none at all, and this is asked for
  # every account rendered.
  #
  # Keyed by domain because a local account's shortcodes are ours and a remote
  # account's are its own server's: `:blobcat:` there and `:blobcat:` here are
  # two pictures with one name, and crossing them would put an image on
  # somebody's profile that they never chose.
  # The domains a page needs a table for: the authors whose names use a
  # shortcode, and the posts that do. A post's shortcodes belong to its
  # author's server, which is why both sides key on the same domain.
  defp emoji_tables_for(accounts, statuses) do
    from_accounts =
      accounts
      |> Enum.filter(fn account ->
        Enum.any?(emoji_texts(account), &(Formatter.shortcodes(&1) != []))
      end)
      |> Enum.map(& &1.domain)

    domains = Map.new(accounts, &{&1.id, &1.domain})

    from_statuses =
      statuses
      |> Enum.filter(&(Formatter.shortcodes(status_emoji_text(&1)) != []))
      |> Enum.map(&Map.get(domains, &1.account_id))

    (from_accounts ++ from_statuses) |> Enum.uniq() |> Map.new(&{&1, table_for(&1)})
  end

  defp emoji_tables(accounts) do
    accounts
    |> Enum.filter(fn account ->
      Enum.any?(emoji_texts(account), &(Formatter.shortcodes(&1) != []))
    end)
    |> Enum.map(& &1.domain)
    |> Enum.uniq()
    |> Map.new(&{&1, table_for(&1)})
  end

  defp table_for(nil), do: Map.new(Instance.custom_emojis(), &{&1.shortcode, &1})
  defp table_for(domain), do: Instance.remote_emoji(domain)

  defp emoji_in(texts, table) do
    texts
    |> Enum.flat_map(&Formatter.shortcodes/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn code ->
      case Map.fetch(table, code) do
        {:ok, emoji} -> [custom_emoji(emoji)]
        :error -> []
      end
    end)
  end

  # The counters come in rather than being read three times from inside.
  # `stat/2` used to fetch one column per call, so rendering an account was
  # three queries for three columns of the same row, and on a timeline the page
  # then threw all three away and used the ones it had already joined.
  defp rendered_account(account, viewer, counters, emoji \\ %{}, moved \\ %{})

  defp rendered_account(%Account{} = account, _viewer, counters, emoji, moved) do
    %{
      "id" => API.id(account.id),
      "username" => account.username,
      # The bare username for a local account and the full handle for a remote
      # one. That asymmetry is what every client renders, and it is how a
      # reader can tell at a glance which posts came from elsewhere.
      "acct" => acct(account),
      "display_name" => account.display_name || "",
      "locked" => account.locked,
      "bot" => account.bot,
      "discoverable" => account.discoverable,
      "indexable" => account.indexable,
      "group" => account.actor_type == :group,
      "created_at" => timestamp(account.inserted_at),
      "note" => account.note || "",
      "url" => URIs.profile_url(account),
      "uri" => Actor.id(account),
      "avatar" => ProfileImages.url(account, :avatar),
      "avatar_static" => ProfileImages.url(account, :avatar, :static),
      "header" => ProfileImages.url(account, :header),
      "header_static" => ProfileImages.url(account, :header, :static),
      "followers_count" => counters.followers,
      "following_count" => counters.following,
      "statuses_count" => counters.statuses,
      "last_status_at" => last_status_date(counters.last_status),
      "hide_collections" => account.hide_collections,
      # A display name reading `alice :wave:` renders the picture rather than
      # the shortcode, which is the whole point of having them.
      "emojis" => emoji_in(emoji_texts(account), Map.get(emoji, account.domain, %{})),
      # Nothing about somebody this server has taken down, including what they
      # had written about themselves. A suspended profile is a name and a
      # notice, not a profile with a notice on it.
      "fields" =>
        if(suspended?(account), do: [], else: Enum.map(account.fields || [], &field(account, &1))),
      "roles" => roles_of(account, counters),
      # `noindex` is the reader-facing spelling of the same choice `indexable`
      # publishes: one says "let search engines in", the other says "keep them
      # out", and clients read the second. Local accounts only — a remote
      # server's answer is on their profile, not ours.
      "noindex" => if(local?(account), do: not account.indexable)
    }
    |> put_when(suspended?(account), "suspended", true)
    |> put_when(not is_nil(account.silenced_at), "limited", true)
    |> put_when(account.memorial, "memorial", true)
    |> put_when(
      account.moved_to_account_id != nil,
      "moved",
      Map.get(moved, account.moved_to_account_id)
    )
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # Present only when it applies, which is what the reference implementation
  # does and what clients branch on: a `false` here reads as "we checked and
  # they are fine", and an absent key reads the same way with less to carry.
  defp put_when(map, false, _key, _value), do: map
  defp put_when(map, true, key, value), do: Map.put(map, key, value)

  defp suspended?(%Account{suspended_at: at}), do: not is_nil(at)
  defp local?(%Account{domain: domain}), do: is_nil(domain)

  # Local accounts only, and only a role somebody chose to highlight. Nothing
  # at all for an account this server has taken down: their badge is not a
  # thing to keep displaying.
  defp roles_of(account, counters) do
    with true <- local?(account) and not suspended?(account),
         %Role{} = role <- Map.get(counters, :role) do
      [
        %{
          "id" => API.id(role.id),
          "name" => role.name,
          "color" => role.color,
          "permissions" => Integer.to_string(role.permissions),
          "highlighted" => role.highlighted
        }
      ]
    else
      _ -> []
    end
  end

  @doc """
  The profile its owner is editing, which is not the same as the account
  everybody else reads.

  Separate from `account/2` because it answers different questions: it carries
  what is in the edit boxes as well as what is rendered from it, and it leaves
  out every counter, because a page for changing your name has no business
  reporting how many followers the change might reach.
  """
  @spec profile(Account.t()) :: map()
  def profile(%Account{} = account) do
    fields = account.fields || []

    %{
      "id" => API.id(account.id),
      "display_name" => account.display_name || "",
      "note" => account.note || "",
      # The raw text and the rendered HTML side by side: one goes in the edit
      # box, the other is what the profile will look like.
      "formatted_note" => Statuses.content_html(%Status{local: true, text: account.note || ""}),
      "fields" => Enum.map(fields, &raw_field/1),
      "formatted_fields" => Enum.map(fields, &field(account, &1)),
      "avatar" => presence(ProfileImages.url(account, :avatar)),
      "avatar_static" => presence(ProfileImages.url(account, :avatar, :static)),
      "header" => presence(ProfileImages.url(account, :header)),
      "header_static" => presence(ProfileImages.url(account, :header, :static)),
      "locked" => account.locked,
      "bot" => account.bot,
      "discoverable" => account.discoverable,
      "indexable" => account.indexable,
      "hide_collections" => account.hide_collections,
      # Somebody's own list, on their own profile. It says nothing about them
      # to anybody else, so it belongs here rather than in the public entity.
      "attribution_domains" => account.attribution_domains,
      "featured_tags" => featured_tags(account)
    }
  end

  # Null rather than an empty string here, unlike the account entity. The
  # reference implementation sends null on the profile and "" on the account,
  # and a client that renders an edit form reads the null as "no picture yet".
  defp presence(""), do: nil
  defp presence(value), do: value

  defp raw_field(field) do
    %{
      "name" => Map.get(field, :name),
      "value" => Map.get(field, :value),
      "verified_at" => timestamp(Map.get(field, :verified_at))
    }
  end

  @doc """
  A hashtag on somebody's profile.

  The id is the featured row's, not the tag's: it is what a client deletes by,
  and two people featuring one tag have two of them. `statuses_count` is a
  string and `last_status_at` a bare date, both of which are what the reference
  implementation sends and therefore what clients parse.
  """
  @spec featured_tags(Account.t()) :: [map()]
  def featured_tags(%Account{} = account) do
    Enum.map(Statuses.featured_tags(account), &featured_tag(account, &1))
  end

  @doc """
  One of them.
  """
  @spec featured_tag(Account.t(), Abuuba.Statuses.FeaturedTag.t()) :: map()
  def featured_tag(%Account{} = account, featured) do
    %{
      "id" => API.id(featured.id),
      "name" => featured.tag.name,
      # Built off the account's own profile address rather than off this
      # server's plus a bare username. A remote `alice` and a local `alice` are
      # two people, and the second spelling sends a reader to the wrong one.
      "url" => "#{URIs.profile_url(account)}/tagged/#{featured.tag.name}",
      "statuses_count" => Integer.to_string(featured.statuses_count),
      "last_status_at" => last_status_date(featured.last_status_at)
    }
  end

  @doc """
  A poll, as a client renders it.

  `own_votes` is only ever the reader's own. A poll that reported somebody
  else's choices would publish how a person voted, which is not something they
  agreed to when they answered.
  """
  @spec poll(Poll.t() | nil, Account.t() | nil) :: map() | nil
  def poll(poll, viewer \\ nil)
  def poll(nil, _viewer), do: nil

  def poll(%Poll{} = poll, viewer) do
    render_poll(poll, viewer, (viewer && Statuses.own_votes(poll, viewer)) || [])
  end

  defp context_poll(nil, _viewer, _context), do: nil

  defp context_poll(poll, viewer, context) do
    render_poll(poll, viewer, Map.get(context.own_votes, poll.id, []))
  end

  defp render_poll(poll, viewer, own) do
    %{
      "id" => API.id(poll.id),
      "expires_at" => timestamp(poll.expires_at),
      "expired" => Poll.expired?(poll),
      "multiple" => poll.multiple,
      "votes_count" => Enum.sum(poll.tallies),
      "voters_count" => poll.voters_count,
      "options" => options(poll),
      "emojis" => [],
      "voted" => viewer != nil and own != [],
      "own_votes" => own
    }
  end

  @doc """
  The thread around a post. Both halves go through one rendering batch.
  """
  @spec context(map(), Account.t() | nil) :: map()
  def context(%{ancestors: ancestors, descendants: descendants}, viewer \\ nil) do
    {rendered_ancestors, rendered_descendants} =
      (ancestors ++ descendants)
      # A thread is one of the places a filter can name, so the posts in it
      # carry which of the reader's filters matched.
      |> statuses(viewer, filter_context: "thread")
      |> Enum.split(length(ancestors))

    %{
      "ancestors" => rendered_ancestors,
      "descendants" => rendered_descendants
    }
  end

  @doc """
  What somebody would need to edit a post: the text as they typed it, not as it
  renders.
  """
  @spec status_source(Status.t()) :: map()
  def status_source(%Status{} = status) do
    %{
      "id" => API.id(status.id),
      "text" => status.text,
      "spoiler_text" => status.spoiler_text || ""
    }
  end

  @doc """
  One earlier version of a post.
  """
  @spec status_edit(map()) :: map()
  def status_edit(edit) do
    %{
      # Rendered rather than raw. A client puts this straight into the page
      # beside the current version, and the two have to look like the same
      # post: unrendered text shows the markup a local author never typed and
      # kills every link and mention in it.
      "content" => edit_content(edit),
      "spoiler_text" => Map.get(edit, :spoiler_text) || "",
      "sensitive" => Map.get(edit, :sensitive, false),
      "created_at" => timestamp(Map.get(edit, :inserted_at)),
      "account" => nil,
      "poll" => nil,
      "media_attachments" => [],
      "emojis" => []
    }
  end

  # A stored edit carries the text as it was written, which for a local post is
  # plain and for a remote one is already the sender's HTML -- the same
  # distinction `Statuses.content_html/2` makes for the post itself.
  defp edit_content(%Status{} = status), do: Statuses.content_html(status)

  defp edit_content(edit) do
    if Map.get(edit, :local, true) do
      edit |> Map.get(:text) |> to_string() |> Formatter.to_html()
    else
      Map.get(edit, :text) || ""
    end
  end

  @doc """
  A post somebody has written but not published yet.
  """
  @spec scheduled_status(ScheduledStatus.t()) :: map()
  def scheduled_status(%ScheduledStatus{} = scheduled) do
    [rendered] = scheduled_statuses([scheduled])

    rendered
  end

  @doc """
  A page of them, with every upload they hold fetched once.

  One query for the page rather than one per row: a client asks for the
  scheduled list on every compose screen, and twenty scheduled posts were
  twenty queries for a handful of attachments.
  """
  @spec scheduled_statuses([ScheduledStatus.t()]) :: [map()]
  def scheduled_statuses([]), do: []

  def scheduled_statuses(scheduled) do
    by_id = scheduled_media(scheduled)

    Enum.map(scheduled, fn one ->
      %{
        "id" => API.id(one.id),
        "scheduled_at" => timestamp(one.scheduled_at),
        "params" => one.params,
        # The uploads it is holding. A client shows them in the "scheduled"
        # list so somebody can see what is going out, and an empty array here
        # made every scheduled post look like plain text.
        "media_attachments" =>
          Enum.flat_map(one.media_attachment_ids, fn id ->
            by_id |> Map.get({one.account_id, id}) |> List.wrap()
          end)
      }
    end)
  end

  # Keyed by `{account_id, id}`, which is what narrows it to each scheduler's
  # own uploads. Without that an id in the request was enough to have a
  # stranger's alt text, filename, dimensions and URL rendered straight back —
  # ids are timestamped, so a run of them is guessable, and a scheduled post is
  # not one anybody has to publish.
  defp scheduled_media(scheduled) do
    ids = Enum.flat_map(scheduled, & &1.media_attachment_ids)
    accounts = Enum.map(scheduled, & &1.account_id)

    if ids == [] do
      %{}
    else
      Attachment
      |> where([a], a.id in ^ids and a.account_id in ^accounts)
      |> Repo.all()
      |> Map.new(&{{&1.account_id, &1.id}, media_attachment(&1)})
    end
  end

  ## What only the reader can answer

  defp reader_state(_status, nil, _context) do
    # Nobody is reading, so there is no relationship to report. Absent rather
    # than false: a client caching an anonymous response must not then believe
    # the reader has favourited nothing.
    %{}
  end

  defp reader_state(%Status{id: id} = status, %Account{}, context) do
    %{
      "favourited" => MapSet.member?(context.favourited, id),
      "reblogged" => MapSet.member?(context.reblogged, id),
      "bookmarked" => MapSet.member?(context.bookmarked, id),
      "muted" => MapSet.member?(context.muted_conversations, status.conversation_id),
      "pinned" => MapSet.member?(context.pinned, id)
    }
  end

  # Everything a page of posts needs, in a fixed number of queries whatever the
  # page size. The boosted posts are gathered too, since a page of boosts would
  # otherwise be a second N+1 hiding inside the first.
  defp gather(statuses, viewer, opts) do
    boosted_ids = statuses |> Enum.map(& &1.reblog_of_id) |> Enum.reject(&is_nil/1)

    originals =
      if boosted_ids == [] do
        []
      else
        Statuses.not_deleted()
        |> Statuses.visible_to(viewer)
        |> where([s], s.id in ^boosted_ids)
        |> Repo.all()
      end

    all = statuses ++ originals
    all_ids = Enum.map(all, & &1.id)

    account_ids =
      all
      # Authors only. `in_reply_to_account_id` used to be collected here too,
      # but nothing reads it: the reply's *id* is rendered from the status row
      # and the account it names is never looked up. On a page of twenty
      # replies to twenty strangers that fetched twenty-one accounts and built
      # twenty-one rendered maps to use one.
      |> Enum.map(& &1.account_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    authors = accounts_with_stats(account_ids)

    # One table per domain on the page, for the page's posts and its authors
    # together. A timeline whose posts use no shortcodes but whose authors do
    # still needs one, and asking twice would be two passes over the same list
    # for the same answer.
    emoji =
      emoji_tables_for(
        Enum.map(authors, fn {account, _counters} -> account end),
        all
      )

    interactions = interactions(viewer, all_ids)
    polls = polls_by_status(all_ids)
    tags = tags_by_status(all_ids)
    moved = moved_targets(Enum.map(authors, fn {account, _c} -> account end), viewer)
    filter_context = Keyword.get(opts, :filter_context)
    filters = reader_filters(viewer, filter_context)

    %{
      accounts: Map.new(authors, fn {account, _counters} -> {account.id, account} end),
      # Rendered once per account rather than once per post. A page of twenty
      # from one author is one author, and their counters do not change while
      # the page is being built.
      rendered_accounts:
        Map.new(authors, fn {account, counters} ->
          {account.id, rendered_account(account, viewer, counters, emoji, moved)}
        end),
      counts: counts_by_status(all_ids),
      mentions: mentions_by_status(all_ids),
      tags: tags,
      polls: polls,
      # The reader's choices across every poll on the page, in one query
      # rather than one per poll.
      own_votes: Statuses.own_votes_by_poll(Map.values(polls), viewer),
      media: media_by_status(all),
      cards: cards_by_status(all_ids),
      quotes: Quotes.accepted_by_status(all_ids),
      emoji: emoji,
      # One map of shortcode to image per domain, not one flattened map. A
      # flattened one would render a local post's `:blobcat:` with another
      # server's picture the moment both had that name, which is the whole
      # thing this keeps apart.
      emoji_urls:
        Map.new(emoji, fn {domain, table} ->
          {domain, Map.new(table, fn {code, e} -> {code, e.image_url} end)}
        end),
      originals: Map.new(originals, &{&1.id, &1}),
      favourited: interactions.favourited,
      bookmarked: interactions.bookmarked,
      pinned: interactions.pinned,
      reblogged: interactions.reblogged,
      muted_conversations: muted_conversations(viewer, all),
      applications: applications_by_status(all),
      collections_by_tag: collections_by_tag(tags),
      shows_application: shows_application_by_account(authors),
      filter_context: filter_context,
      # Once for the page. These are the reader's own rules and they do not
      # change between the first post and the twentieth, so asking per post was
      # the largest per-status query left in a timeline.
      filters: filters,
      # Rendered once each, not once per post they match. A page of twenty
      # posts against one rule built the same map twenty times.
      rendered_filters: Map.new(filters, &{&1.id, filter(&1)})
    }
  end

  # Only where a caller said which context it is rendering for: without one
  # there is no filtering to do, and every anonymous page takes that path.
  defp reader_filters(nil, _context), do: []
  defp reader_filters(_viewer, nil), do: []
  defp reader_filters(viewer, _context), do: Filters.all(viewer)

  # The authors and their counters together, as `{account, counters}` pairs.
  # They were two queries, and the second always followed the first with the
  # same ids, which is a join written across two round trips.
  #
  # Left, not inner: an account with no `account_stats` row yet still has to
  # come back. `coalesce` turns the nulls that produces into the zeros every
  # caller wants, so nothing downstream has to know the row was missing.
  defp accounts_with_stats([]), do: []

  defp accounts_with_stats(ids) do
    Account
    |> where([a], a.id in ^ids)
    |> join(:left, [a], s in "account_stats", on: s.account_id == a.id)
    # The author's settings ride along on the query that was fetching them
    # anyway. It is one field out of the map, and asking for it separately
    # would be a second pass over the page's authors for one boolean.
    |> join(:left, [a, _s], u in User, on: u.account_id == a.id)
    |> join(:left, [_a, _s, u], r in Role, on: r.id == u.role_id and r.highlighted)
    |> select([a, s, u, r], {
      a,
      %{
        followers: coalesce(s.followers_count, 0),
        following: coalesce(s.following_count, 0),
        statuses: coalesce(s.statuses_count, 0),
        last_status: s.last_status_at,
        settings: u.settings,
        # Only a highlighted role. The rest exist to grant permissions, and
        # publishing them would tell every reader how this server's moderation
        # is organised.
        role: r
      }
    })
    |> Repo.all()
  end

  # A date, not a moment: the API reports the day somebody last said
  # something, and clients render it as exactly that. The naive clause is for
  # the schemaless join, which hands timestamps back without a zone.
  defp last_status_date(nil), do: nil
  defp last_status_date(%DateTime{} = at), do: at |> DateTime.to_date() |> Date.to_iso8601()

  defp last_status_date(%NaiveDateTime{} = at),
    do: at |> NaiveDateTime.to_date() |> Date.to_iso8601()

  # Read off the maintained counters rather than counted, so the cost of a
  # page is the page and not how loved its posts are. `Abuuba.Statuses` moves
  # them on every write; the rows in `statuses` and `favourites` stay the
  # truth to recount from.
  defp counts_by_status([]), do: %{}

  defp counts_by_status(ids) do
    from(ss in "status_stats",
      where: ss.status_id in ^ids,
      select: {
        ss.status_id,
        %{
          replies: ss.replies_count,
          reblogs: ss.reblogs_count,
          favourites: ss.favourites_count,
          quotes: ss.quotes_count
        }
      }
    )
    |> Repo.all()
    |> Map.new()
  end

  # The mentions and the emoji were loaded for the whole page already, so the
  # linking reuses them rather than asking again per post. Without this a
  # timeline of twenty posts is twenty more round trips.
  defp content_html(status, mentions, context) do
    Statuses.content_html(status,
      accounts: Map.new(mentions, &{&1["acct"], &1["url"]}),
      emojis: emoji_urls_for(status, context)
    )
  end

  # The author's own server's pictures and nobody else's, for the same reason
  # the entity's `emojis` list is keyed that way.
  defp emoji_urls_for(status, %{emoji_urls: %{} = by_domain} = context) do
    domain = author_domain(status, context)

    # A miss means the page found no shortcodes for that domain, which is the
    # ordinary case. Reaching for the table here instead would be a query per
    # post on every page that uses no emoji at all.
    Map.get(by_domain, domain, %{})
  end

  defp emoji_urls_for(_status, _context), do: %{}

  # A remote post's page is on its own server. Ours is the page this server
  # renders, which is not the same address as the object other servers fetch:
  # handing out the object id would send a reader to a JSON document.
  defp web_url(%Status{local: false} = status, account) do
    status.url || Serializer.status_uri(status, account)
  end

  defp web_url(%Status{} = status, account), do: URIs.status_url(account, status.id)

  # Asked for only when a page actually carries a shortcode. Most do not, and
  # a query per timeline render for a table nobody on the page mentions is a
  # round trip bought for nothing.
  # Only our own posts. Another server's `:wave:` is theirs, and lending it one
  # of our pictures puts an image in somebody's post that they never chose.
  defp status_emoji_text(%Status{local: true, text: text}), do: text || ""
  defp status_emoji_text(%Status{}), do: ""

  # Ours from ours, theirs from theirs, and never crossed: another server's
  # `:wave:` is a different picture with the same name, and lending it one of
  # ours would put an image in somebody's post that they never chose.
  # Asked at all only for a post that uses a shortcode, which most do not. The
  # table lookup is cheap and the domain lookup behind it need not be, so the
  # cheapest question comes first.
  defp emojis_used(%Status{} = status, context) do
    case Formatter.shortcodes(status.text) do
      [] -> []
      codes -> pick_emoji(codes, table_in(context, author_domain(status, context)))
    end
  end

  defp pick_emoji(codes, table) do
    Enum.flat_map(codes, fn code ->
      case Map.fetch(table, code) do
        {:ok, emoji} -> [custom_emoji(emoji)]
        :error -> []
      end
    end)
  end

  # A context built by `gather/3` holds a table per domain; one built for a
  # single status may hold none, and reads it then. Either way the shortcodes
  # come from the author's own server.
  defp table_in(%{emoji: %{} = tables}, domain) do
    # Same reasoning as `emoji_urls_for/2`: the page already worked out which
    # domains need a table, so a miss is "none needed" rather than a reason to
    # go and look.
    Map.get(tables, domain, %{})
  end

  defp table_in(_context, domain), do: table_for(domain)

  # From what the page has already loaded, in the order that costs least: the
  # batch's own account map, then a preloaded association, and only then the
  # database. Without the first two this was a query per post on every page,
  # which is exactly what the batched rendering exists to avoid.
  defp author_domain(%Status{} = status, %{accounts: accounts}) when is_map(accounts) do
    case Map.fetch(accounts, status.account_id) do
      {:ok, %Account{domain: domain}} -> domain
      :error -> author_domain(status, nil)
    end
  end

  defp author_domain(%Status{account: %Account{domain: domain}}, _context), do: domain

  defp author_domain(%Status{account_id: account_id}, _context) do
    case Abuuba.Accounts.get_account(account_id) do
      %Account{domain: domain} -> domain
      _ -> nil
    end
  end

  defp mentions_by_status([]), do: %{}

  defp mentions_by_status(ids) do
    Mention
    |> join(:inner, [m], a in Account, on: a.id == m.account_id)
    |> where([m], m.status_id in ^ids)
    |> order_by([m], asc: m.id)
    |> select([m, a], {m.status_id, a})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_id, account} ->
      %{
        "id" => API.id(account.id),
        "username" => account.username,
        "url" => URIs.profile_url(account),
        "acct" => acct(account)
      }
    end)
  end

  defp tags_by_status([]), do: %{}

  defp tags_by_status(ids) do
    Tag
    |> join(:inner, [t], st in "statuses_tags", on: st.tag_id == t.id)
    |> where([_t, st], st.status_id in ^ids)
    |> order_by([t], asc: t.id)
    |> select([t, st], {st.status_id, t})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_id, tag} ->
      %{"name" => tag.name, "url" => "#{URIs.base_url()}/tags/#{tag.name}"}
    end)
  end

  # One query for the page, like the media and the tags. A card fetched per
  # post is twenty queries for twenty posts, which is the shape the
  # rendering-cost test exists to catch.
  defp cards_by_status([]), do: %{}

  defp cards_by_status(ids) do
    ids
    |> PreviewCards.for_statuses()
    |> Map.new(fn {status_id, card} -> {status_id, preview_card(card)} end)
  end

  # Asked for every page, including the ones whose statuses all have an empty
  # `ordered_media_attachment_ids`. Skipping those looks free and is not: that
  # column is an *ordering* hint, not a record of what exists.
  # `Media.create_attachment/1` sets `status_id` without touching it, and
  # The same rule `Media.for_status/1` applies, batched over a page: the order
  # the author chose first, then anything the status does not list, by id.
  #
  # Both halves matter. Trusting the column alone once dropped the pictures off
  # a post that had them, because an attachment missing from the array became
  # invisible; ignoring it, which is what fixed that, silently reordered every
  # post whose author had arranged their pictures. A reader gets the order that
  # was chosen, and a bookkeeping slip costs the order rather than the picture.
  defp media_by_status([]), do: %{}

  defp media_by_status(statuses) do
    ids = Enum.map(statuses, & &1.id)

    by_status =
      Attachment
      |> where([a], a.status_id in ^ids)
      |> order_by([a], asc: a.id)
      |> Repo.all()
      |> Enum.group_by(& &1.status_id)

    Map.new(statuses, fn status ->
      {status.id, ordered(Map.get(by_status, status.id, []), status)}
    end)
  end

  defp ordered([], _status), do: []

  defp ordered(attachments, status) do
    by_id = Map.new(attachments, &{&1.id, &1})
    listed = Enum.flat_map(status.ordered_media_attachment_ids, &List.wrap(by_id[&1]))
    rest = by_id |> Map.drop(status.ordered_media_attachment_ids) |> Map.values()

    Enum.map(listed ++ Enum.sort_by(rest, & &1.id), &media_attachment/1)
  end

  defp polls_by_status([]), do: %{}

  defp polls_by_status(ids) do
    Poll |> where([p], p.status_id in ^ids) |> Repo.all() |> Map.new(&{&1.status_id, &1})
  end

  # What the reader has already done to the posts on this page: favourited,
  # bookmarked, pinned, boosted. Four questions of the same shape against four
  # tables, asked once.
  #
  # They were four queries, and for a logged-out reader they were four queries
  # that could only ever answer "none of them" — every timeline read a crawler
  # or a link preview makes paid for all four.
  defp interactions(nil, _ids), do: @no_interactions
  defp interactions(_viewer, []), do: @no_interactions

  defp interactions(%Account{id: account_id}, ids) do
    favourited =
      from(f in Favourite,
        where: f.account_id == ^account_id and f.status_id in ^ids,
        select: %{kind: 0, status_id: f.status_id}
      )

    bookmarked =
      from(b in Bookmark,
        where: b.account_id == ^account_id and b.status_id in ^ids,
        select: %{kind: 1, status_id: b.status_id}
      )

    pinned =
      from(p in Pin,
        where: p.account_id == ^account_id and p.status_id in ^ids,
        select: %{kind: 2, status_id: p.status_id}
      )

    # The odd one out: a boost is a status of its own, so what identifies it is
    # what it points at rather than a `status_id` column.
    reblogged =
      from(s in Status,
        where: s.account_id == ^account_id and s.reblog_of_id in ^ids,
        where: is_nil(s.deleted_at),
        select: %{kind: 3, status_id: s.reblog_of_id}
      )

    favourited
    |> union_all(^bookmarked)
    |> union_all(^pinned)
    |> union_all(^reblogged)
    |> Repo.all()
    |> Enum.reduce(@no_interactions, fn %{kind: kind, status_id: id}, acc ->
      Map.update!(acc, @interaction_fields[kind], &MapSet.put(&1, id))
    end)
  end

  # One query for the page's applications rather than one per post. A timeline
  # is usually one or two apps over and over.
  defp applications_by_status(statuses) do
    ids = statuses |> Enum.map(& &1.application_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      from(a in Application, where: a.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})
    end
  end

  # Whether each author has left the "via <app>" line on, read off the settings
  # that came back with the page's authors. A remote author has no settings
  # here at all, which is the same answer as "on": their server decides what
  # it publishes and we show what arrives.
  defp shows_application_by_account(authors) do
    Map.new(authors, fn {account, counters} ->
      {account.id, PostingDefaults.for_user(%{settings: counters.settings})["show_application"]}
    end)
  end

  # Shown when the author has left it on, and always to the author themselves
  # on their own posts — somebody who turned it off still wants to see which
  # app they wrote something in. Never for a post from another server: what
  # arrives over the wire is that server's word for it, not a row here.
  defp application_of(%Status{local: false}, _viewer, _context), do: nil
  defp application_of(%Status{application_id: nil}, _viewer, _context), do: nil

  defp application_of(%Status{} = status, viewer, context) do
    own? = viewer != nil and viewer.id == status.account_id
    shown? = Map.get(context.shows_application, status.account_id, true)

    with true <- own? or shown?,
         %{} = application <- Map.get(context.applications, status.application_id) do
      %{"name" => application.name, "website" => presence(application.website)}
    else
      _ -> nil
    end
  end

  # Absent unless a caller said which context it is rendering for. A filter
  # applies in some places and not others, so "which filters matched" has no
  # answer without knowing where the post is being shown, and a wrong answer
  # would have a client folding away posts nobody asked it to.
  defp merge_filtered(rendered, _status, nil, _context), do: rendered

  defp merge_filtered(rendered, status, _viewer, context) do
    case context.filter_context do
      nil -> rendered
      where -> Map.put(rendered, "filtered", filtered(status, where, context))
    end
  end

  # Which of the reader's own filters matched, and what they asked be done.
  #
  # Attached to the status rather than acted on. A filter is a reading
  # preference rather than moderation: the post is delivered, the client folds
  # it away or removes it, and the reader can lift the rule and see what they
  # missed.
  defp filtered(status, where, context) do
    context.filters
    |> Filters.match(status, where)
    |> Enum.map(fn matched ->
      %{
        "filter" => Map.fetch!(context.rendered_filters, matched.id),
        "keyword_matches" => [],
        "status_matches" => []
      }
    end)
  end

  @doc """
  One matched filter, in the shape a status carries it.

  Public because the live timelines match a single arriving post themselves —
  their rendering comes from a cache shared by every watcher, which cannot
  carry an answer that is one reader's. Two places building this shape by hand
  is two shapes that quietly stop agreeing.
  """
  @spec filter_result(Filter.t()) :: map()
  def filter_result(%Filter{} = matched) do
    %{"filter" => filter(matched), "keyword_matches" => [], "status_matches" => []}
  end

  # Read off the hashtags the page already gathered, and skipped entirely when
  # there are none — which is most pages, and is what keeps this off the
  # rendering budget for a timeline of plain posts.
  defp collections_by_tag(tags) when map_size(tags) == 0, do: %{}

  defp collections_by_tag(tags) do
    names = tags |> Map.values() |> List.flatten() |> Enum.map(& &1["name"]) |> Enum.uniq()

    by_name =
      names
      |> Collections.for_tags(limit: 40)
      |> Enum.group_by(& &1.tag.name)

    Map.new(tags, fn {status_id, status_tags} ->
      {status_id,
       status_tags
       |> Enum.flat_map(&Map.get(by_name, &1["name"], []))
       |> Enum.uniq_by(& &1.id)
       |> Enum.take(4)}
    end)
  end

  defp tagged_collections(status, context) do
    context.collections_by_tag |> Map.get(status.id, []) |> collections()
  end

  defp muted_conversations(nil, _statuses), do: MapSet.new()

  defp muted_conversations(%Account{id: account_id}, statuses) do
    ids = statuses |> Enum.map(& &1.conversation_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      MapSet.new()
    else
      ConversationMute
      |> where([m], m.account_id == ^account_id and m.conversation_id in ^ids)
      |> select([m], m.conversation_id)
      |> Repo.all()
      |> MapSet.new()
    end
  end

  ## Pieces

  defp boosted(%Status{reblog_of_id: nil}, _viewer, _context), do: nil

  defp boosted(%Status{reblog_of_id: id}, viewer, context) do
    case Map.get(context.originals, id) do
      nil -> nil
      original -> render(original, viewer, context)
    end
  end

  defp options(%Poll{options: options, tallies: tallies}) do
    options
    |> Enum.with_index()
    |> Enum.map(fn {title, index} ->
      %{"title" => title, "votes_count" => Enum.at(tallies, index, 0)}
    end)
  end

  defp field(account, field) do
    %{
      "name" => field.name,
      "value" => field_value(account, field.value),
      "verified_at" => timestamp(Map.get(field, :verified_at))
    }
  end

  # `value` is HTML in this API: every client renders it as markup rather than
  # as text. So ours, which is plain text somebody typed, is escaped here, and
  # theirs, which is markup that was cleaned when it arrived, is passed through.
  # Without the escape a local account writing a `<script>` into a field owns
  # every client that shows the profile — and can hand-draw a Verified badge
  # next to a link nobody checked.
  defp field_value(%Account{domain: nil}, value), do: escape(value)
  defp field_value(_account, value), do: value

  defp escape(nil), do: ""

  defp escape(value) when is_binary(value) do
    value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  defp acct(%Account{domain: nil, username: username}), do: username
  defp acct(%Account{} = account), do: URIs.full_handle(account)

  defp account_of(%Status{account: %Account{} = account}), do: account
  defp account_of(%Status{account_id: id}), do: Repo.get(Account, id)

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = at), do: DateTime.to_iso8601(at)

  @doc """
  One account's relationship to another, as a client's buttons read it.
  """
  @spec relationship(map()) :: map()
  def relationship(relationship) do
    %{
      "id" => API.id(relationship.id),
      "following" => relationship.following,
      "followed_by" => relationship.followed_by,
      "blocking" => relationship.blocking,
      "blocked_by" => relationship.blocked_by,
      "muting" => relationship.muting,
      "muting_notifications" => relationship.muting_notifications,
      # When a timed mute lifts itself, so a client can say "muted until six",
      # and null when the mute has no end.
      "muting_expires_at" => timestamp(relationship.muting_expires_at),
      "requested" => relationship.requested,
      "requested_by" => relationship.requested_by,
      "showing_reblogs" => relationship.showing_reblogs,
      "notifying" => relationship.notifying,
      "languages" => relationship.languages,
      "domain_blocking" => false,
      "endorsed" => relationship.endorsed,
      "note" => relationship.note || ""
    }
  end

  @doc """
  A report, as the client API hands it back.
  """
  @spec report(Abuuba.Moderation.Report.t()) :: map()
  def report(%Abuuba.Moderation.Report{} = report) do
    %{
      "id" => API.id(report.id),
      "action_taken" => not is_nil(report.action_taken_at),
      "action_taken_at" => timestamp(report.action_taken_at),
      "category" => report.category,
      "comment" => report.comment || "",
      "forwarded" => report.forwarded,
      "created_at" => timestamp(report.inserted_at),
      "status_ids" => Enum.map(report.status_ids, &API.id/1),
      "rule_ids" => Enum.map(report.rule_ids, &API.id/1),
      "target_account" => account(Abuuba.Accounts.get_account(report.target_account_id))
    }
  end

  @doc """
  A role, as the admin API hands it out.

  The permissions travel as the decimal string of the bitmask, which is what
  the reference implementation sends and therefore what a client parses.
  """
  @spec role(Abuuba.Roles.Role.t() | nil) :: map() | nil
  def role(nil), do: nil

  def role(%Abuuba.Roles.Role{} = role) do
    %{
      "id" => API.id(role.id),
      "name" => role.name,
      "permissions" => to_string(role.permissions),
      "color" => role.color,
      "highlighted" => role.highlighted
    }
  end

  @doc """
  What an account's owner sees about themselves that nobody else does.
  """
  @spec account_source(Account.t()) :: map()
  def account_source(%Account{} = account) do
    %{
      "note" => account.note || "",
      # Raw, not rendered. `source` is what goes back into the edit box, so a
      # value that arrived as `<3` has to come back as `<3` rather than as the
      # entity's escaped `&lt;3`, which would grow an escape on every save.
      "fields" => Enum.map(account.fields || [], &raw_field/1),
      "privacy" => "public",
      "sensitive" => false,
      "language" => nil,
      "follow_requests_count" => 0,
      # Where the reference implementation puts it on `verify_credentials`, so
      # a client that already knows how to edit this list finds it here.
      "attribution_domains" => account.attribution_domains
    }
  end

  @doc """
  Which field a validation refused, and why.

  Named per field rather than folded into one sentence, because a form has to
  put the message next to the box somebody typed in.
  """
  @spec field_errors(Ecto.Changeset.t()) :: map()
  def field_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      %{
        "error" => "ERR_INVALID",
        "description" =>
          Regex.replace(~r/%\{(\w+)\}/, message, fn _whole, key ->
            opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
          end)
      }
    end)
  end

  @doc """
  One notification, as a client renders it.
  """
  @spec notification(Notification.t(), Account.t() | nil) :: map()
  def notification(%Notification{} = notification, viewer \\ nil) do
    [rendered] = notifications([notification], viewer)

    rendered
  end

  @doc """
  A page of notifications, the senders and the referenced posts each loaded
  once for the page.

  Rendering per row cost a full status-render batch per notification — a
  page of forty was hundreds of round trips.
  """
  @spec notifications([Notification.t()], Account.t() | nil) :: [map()]
  def notifications(notifications, viewer \\ nil)
  def notifications([], _viewer), do: []

  def notifications(notifications, viewer) do
    senders =
      notifications
      |> Enum.map(& &1.from_account_id)
      |> rendered_accounts_by_id(viewer)

    # With the context the reader's own filters name. Without it no filters are
    # loaded at all, so a filter set to apply to notifications did nothing for
    # anybody reading through an app -- the web page passed its context and
    # this did not.
    statuses =
      statuses_by_id(
        Enum.map(notifications, & &1.status_id),
        viewer,
        filter_context: "notifications"
      )

    Enum.map(notifications, fn notification ->
      %{
        "id" => API.id(notification.id),
        "type" => notification.type,
        "created_at" => timestamp(notification.inserted_at),
        "group_key" => notification.group_key,
        "account" => senders[notification.from_account_id],
        "status" => notification.status_id && statuses[to_string(notification.status_id)]
      }
    end)
  end

  # Rendered accounts for a list of ids that may hold nils and repeats.
  defp rendered_accounts_by_id(ids, viewer) do
    ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> accounts_with_stats()
    |> Map.new(fn {account, counters} ->
      {account.id, rendered_account(account, viewer, counters)}
    end)
  end

  @doc """
  Rendered statuses the viewer may see, keyed by their string id, for a list
  of ids that may hold nils and repeats.

  For pages that reference posts by id — notifications, conversations, the
  requests inbox: one visibility-checked fetch and one rendering batch, and a
  post the viewer may not see is simply absent from the map.
  """
  @spec statuses_by_id([integer() | nil], Account.t() | nil) :: %{String.t() => map()}
  def statuses_by_id(ids, viewer, opts \\ []) do
    ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Statuses.get_visible_statuses(viewer)
    |> statuses(viewer, opts)
    |> Map.new(&{&1["id"], &1})
  end

  @doc """
  A page of them, one entry per group.

  A type the client did not say it can group is answered as its own group of
  one, so a client written before a type existed still shows it.
  """
  @spec grouped_notifications([map()], Account.t() | nil, [String.t()]) :: map()
  def grouped_notifications(groups, viewer, grouped_types \\ nil) do
    expanded = Enum.flat_map(groups, &split_ungrouped(&1, grouped_types))

    %{
      "notification_groups" => Enum.map(expanded, &notification_group(&1, viewer)),
      "accounts" => grouped_accounts(expanded, viewer),
      "statuses" => grouped_statuses(expanded, viewer)
    }
  end

  @doc """
  One sender in the requests inbox.
  """
  @spec notification_request(Request.t(), Account.t() | nil) :: map()
  def notification_request(%Request{} = request, viewer \\ nil) do
    [rendered] = notification_requests([request], viewer)

    rendered
  end

  @doc """
  The requests inbox as a page, senders and last posts batched.
  """
  @spec notification_requests([Request.t()], Account.t() | nil) :: [map()]
  def notification_requests(requests, viewer \\ nil)
  def notification_requests([], _viewer), do: []

  def notification_requests(requests, viewer) do
    senders = rendered_accounts_by_id(Enum.map(requests, & &1.from_account_id), viewer)

    statuses =
      statuses_by_id(Enum.map(requests, & &1.last_status_id), viewer,
        filter_context: "notifications"
      )

    Enum.map(requests, fn request ->
      %{
        "id" => API.id(request.id),
        "created_at" => timestamp(request.inserted_at),
        "updated_at" => timestamp(request.updated_at),
        "notifications_count" => Integer.to_string(request.notifications_count),
        "account" => senders[request.from_account_id],
        "last_status" => request.last_status_id && statuses[to_string(request.last_status_id)]
      }
    end)
  end

  @doc """
  Somebody's notification policy.
  """
  @spec notification_policy(Policy.t()) :: map()
  def notification_policy(%Policy{} = policy) do
    Map.new(Policy.axes(), fn axis -> {Atom.to_string(axis), Map.get(policy, axis)} end)
  end

  @doc """
  A translated post, in the shape a client expects to receive.
  """
  @spec translation(map()) :: map()
  def translation(translation) do
    %{
      "content" => translation.content,
      "spoiler_text" => translation.spoiler_text || "",
      "detected_source_language" => translation.detected_source_language,
      "provider" => translation.provider,
      "poll" => translated_poll(translation.poll),
      "media_attachments" =>
        Enum.map(translation.media_attachments, fn attachment ->
          %{"id" => attachment.id, "description" => attachment.description}
        end)
    }
  end

  defp translated_poll(nil), do: nil

  defp translated_poll(poll) do
    %{
      "id" => poll.id,
      "options" => Enum.map(poll.options, &%{"title" => &1.title})
    }
  end

  @doc """
  A link somebody shared, as a client renders it.
  """
  @spec preview_card(map()) :: map()
  def preview_card(card) do
    # Every string is present and empty rather than missing: a client reading a
    # card reads all of them, and a missing key is a crash where an empty
    # string is a plain-looking entry.
    strings =
      Map.new(
        ~w(title description author_name author_url provider_name provider_url html
           image_description embed_url)a,
        fn field -> {Atom.to_string(field), Map.get(card, field) || ""} end
      )

    Map.merge(strings, %{
      "url" => card.url,
      "type" => card.type,
      "width" => card.width || 0,
      "height" => card.height || 0,
      "image" => card.image_url,
      "blurhash" => card.blurhash,
      "authors" => authors_of(card),
      "published_at" => nil,
      "language" => nil
    })
  end

  # Present only where the site named somebody this server could resolve, so a
  # client showing it is showing an account rather than a claim.
  defp authors_of(card) do
    case card.author_account_id && Abuuba.Accounts.get_account(card.author_account_id) do
      nil ->
        []

      author ->
        [
          %{
            "name" => card.author_name || "",
            "url" => card.author_url || "",
            "account" => account(author, nil)
          }
        ]
    end
  end

  @doc """
  A page of trending links, each in the preview-card shape a client expects,
  the cards fetched in one query.

  The fields a card carries and this cannot are present and empty rather than
  missing: a client that renders a card reads them, and a missing key is a
  crash where an empty string is a plain-looking entry.
  """
  @spec trend_links([map()]) :: [map()]
  def trend_links(trends) do
    cards = PreviewCards.get_by_urls(Enum.map(trends, & &1.subject))

    Enum.map(trends, &trend_link(&1, cards[&1.subject]))
  end

  defp trend_link(trend, found_card) do
    # The card where one exists, which is nearly always: a link trends because
    # posts carried it, and attaching a card is what put it in the count. The
    # fields a card cannot fill stay present and empty, so a client that
    # renders one never meets a missing key.
    card =
      case found_card do
        nil -> %{}
        card -> preview_card(card)
      end

    bare = %{
      "url" => trend.subject,
      "title" => "",
      "description" => "",
      "type" => "link",
      "provider_name" => URI.parse(trend.subject).host || "",
      "provider_url" => "",
      "author_name" => "",
      "author_url" => "",
      "html" => "",
      "width" => 0,
      "height" => 0,
      "image" => nil,
      "image_description" => "",
      "embed_url" => "",
      "blurhash" => nil,
      "authors" => [],
      "published_at" => nil,
      "language" => nil
    }

    bare
    |> Map.merge(card)
    |> Map.put("history", [
      %{
        "day" => to_string(DateTime.to_unix(DateTime.new!(Date.utc_today(), ~T[00:00:00]))),
        "accounts" => to_string(trend.accounts),
        "uses" => to_string(trend.uses)
      }
    ])
  end

  @doc """
  An account as a moderator sees it: the public entity plus what only they may
  read.
  """
  @spec admin_account(Account.t()) :: map()
  def admin_account(%Account{} = account) do
    [rendered] = admin_accounts([account])

    rendered
  end

  defp role_entity(nil), do: nil

  defp role_entity(role),
    do: %{"id" => API.id(role.id), "name" => role.name, "permissions" => role.permissions}

  @doc """
  A list of accounts as a moderator sees them, with the users, the roles and
  the public entities each fetched once for the whole list rather than once
  per row.
  """
  @spec admin_accounts([Account.t()]) :: [map()]
  def admin_accounts(accounts) do
    users = Abuuba.Admin.users_for(accounts)
    roles = users |> Map.values() |> Enum.map(& &1.role_id) |> Abuuba.Roles.by_ids()

    accounts
    |> Enum.zip(accounts(accounts, nil))
    |> Enum.map(fn {account, public} ->
      user = Map.get(users, account.id)

      %{
        "id" => API.id(account.id),
        "username" => account.username,
        "domain" => account.domain,
        "created_at" => timestamp(account.inserted_at),
        # Only ever here. The public account entity must never carry it, and
        # the two shapes existing side by side is how that gets forgotten.
        "email" => user && user.email,
        "role" => user && role_entity(roles[user.role_id]),
        "confirmed" => user != nil and user.confirmed_at != nil,
        "approved" => user == nil or user.approved,
        "disabled" => user != nil and User.disabled?(user),
        "suspended" => account.suspended_at != nil,
        "silenced" => account.silenced_at != nil,
        "sensitized" => account.sensitized_at != nil,
        "account" => public
      }
    end)
  end

  @doc """
  A report as a moderator sees it.
  """
  @spec admin_report(map()) :: map()
  def admin_report(report) do
    [rendered] = admin_reports([report])

    rendered
  end

  @doc """
  A page of reports, the four accounts each one names all fetched and
  rendered once for the page.
  """
  @spec admin_reports([map()]) :: [map()]
  def admin_reports(reports) do
    rendered =
      reports
      |> Enum.flat_map(&report_account_ids/1)
      |> Enum.uniq()
      |> Abuuba.Accounts.get_accounts()
      |> Map.values()
      |> admin_accounts()
      |> Map.new(fn entity -> {entity["id"], entity} end)

    by_id = fn id -> id && rendered[API.id(id)] end

    Enum.map(reports, fn report ->
      %{
        "id" => API.id(report.id),
        "action_taken" => report.action_taken_at != nil,
        "action_taken_at" => timestamp(report.action_taken_at),
        "category" => report.category,
        "comment" => report.comment,
        "forwarded" => report.forwarded,
        "created_at" => timestamp(report.inserted_at),
        "updated_at" => timestamp(report.updated_at),
        "account" => by_id.(report.account_id),
        "target_account" => by_id.(report.target_account_id),
        "assigned_account" => by_id.(report.assigned_account_id),
        "action_taken_by_account" => by_id.(report.action_taken_by_account_id),
        "status_ids" => Enum.map(report.status_ids || [], &API.id/1),
        "rule_ids" => Enum.map(report.rule_ids || [], &API.id/1)
      }
    end)
  end

  defp report_account_ids(report) do
    Enum.reject(
      [
        report.account_id,
        report.target_account_id,
        report.assigned_account_id,
        report.action_taken_by_account_id
      ],
      &is_nil/1
    )
  end

  @doc """
  A domain block as a moderator sees it, private comment included.
  """
  @spec admin_domain_block(map()) :: map()
  def admin_domain_block(block) do
    %{
      "id" => API.id(block.id),
      "domain" => block.domain,
      "created_at" => timestamp(block.inserted_at),
      "severity" => block.severity,
      "reject_media" => block.reject_media,
      "reject_reports" => block.reject_reports,
      "private_comment" => block.private_comment,
      "public_comment" => block.public_comment,
      "obfuscate" => block.obfuscate
    }
  end

  @doc """
  A year in review, in the envelope a client expects.

  The posts named in a report are carried alongside rather than inside it, the
  same way a grouped notification carries its statuses: the report names ids
  and the envelope holds each post once.
  """
  @spec annual_reports([Abuuba.AnnualReports.Report.t()], Account.t() | nil) :: map()
  def annual_reports(reports, viewer \\ nil) do
    ids =
      reports
      |> Enum.flat_map(&Map.get(&1.data, "top_statuses", []))
      |> Enum.map(&API.parse_id(&1["id"]))
      |> Enum.reject(&is_nil/1)

    # Through the viewer-aware read, so a report never carries a post the
    # person reading it may not see — a shared report is read by strangers.
    found =
      if ids == [],
        do: [],
        else: Enum.flat_map(ids, fn id -> List.wrap(Statuses.get_status(id, viewer)) end)

    %{
      "annual_reports" => Enum.map(reports, &annual_report/1),
      "accounts" => [],
      "statuses" => statuses(found, viewer)
    }
  end

  @doc """
  One of them.
  """
  @spec annual_report(Abuuba.AnnualReports.Report.t()) :: map()
  def annual_report(report) do
    %{
      "year" => report.year,
      "schema_version" => report.schema_version,
      "data" => report.data
    }
  end

  @doc """
  Work a client is waiting on.

  Wrapped in `async_refresh` rather than served flat, which is the shape
  clients already parse.
  """
  @spec async_refresh(AsyncRefresh.t()) :: map()
  def async_refresh(refresh) do
    %{
      "async_refresh" => %{
        "id" => API.id(refresh.id),
        "status" => refresh.status,
        # Null where the refresh is not counting, which is what the reference
        # implementation emits and therefore what clients parse. Zeroing it
        # would say "nothing found yet" about work that has nothing to find.
        "result_count" => refresh.result_count
      }
    }
  end

  @doc """
  A curated list of accounts, as a client renders it.
  """
  @spec collection(Collection.t()) :: map()
  def collection(collection) do
    %{
      "id" => API.id(collection.id),
      # `uri` is what other servers point at and `url` is what a person opens,
      # the same split a post has.
      "uri" => collection.uri || "#{URIs.base_url()}/ap/collections/#{collection.id}",
      "url" => collection.url || collection_url(collection),
      "name" => collection.name,
      "description" => collection.description || "",
      "language" => collection.language,
      "account_id" => API.id(collection.account_id),
      "local" => collection.local,
      "sensitive" => collection.sensitive,
      "discoverable" => collection.discoverable,
      "item_count" => collection.item_count,
      "tag" => collection_tag(collection),
      "items" => Enum.map(Collections.items(collection), &collection_item/1),
      "created_at" => timestamp(collection.inserted_at),
      "updated_at" => timestamp(collection.updated_at)
    }
  end

  @doc """
  Several at once.
  """
  @spec collections([Collection.t()]) :: [map()]
  def collections(collections), do: Enum.map(collections, &collection/1)

  @doc """
  One account on a list.

  `account_id` is absent once somebody has taken themselves off, because a
  revoked entry that still named them would be the list going on saying it.
  """
  @spec collection_item(CollectionItem.t()) :: map()
  def collection_item(item) do
    %{"id" => API.id(item.id), "state" => item.state, "created_at" => timestamp(item.inserted_at)}
    |> put_when(CollectionItem.visible?(item), "account_id", API.id(item.account_id))
  end

  defp collection_url(collection), do: "#{URIs.base_url()}/collections/#{collection.id}"

  defp collection_tag(%{tag: %Tag{} = tag}), do: %{"name" => tag.name}
  defp collection_tag(_collection), do: nil

  @doc """
  A hashtag, as the screen that decides what it may do renders it.
  """
  @spec admin_tag(Abuuba.Statuses.Tag.t()) :: map()
  def admin_tag(tag) do
    %{
      "id" => API.id(tag.id),
      "name" => tag.name,
      "url" => "#{URIs.base_url()}/tags/#{tag.name}",
      "history" => [],
      "usable" => tag.usable,
      "listable" => tag.listable,
      # Null means nobody has decided, which is a different answer from no.
      "trendable" => tag.trendable,
      # What the review queue is for: a tag somebody asked about and nobody has
      # looked at yet.
      "requires_review" => is_nil(tag.reviewed_at)
    }
  end

  @doc """
  A publisher whose links have trended.
  """
  @spec admin_link_publisher(map()) :: map()
  def admin_link_publisher(publisher) do
    %{
      "name" => publisher.provider,
      "url" => "https://#{publisher.provider}",
      "trendable" => publisher.trendable,
      "requires_review" => is_nil(publisher.reviewed_at)
    }
  end

  @doc """
  One measure, as a dashboard draws it.
  """
  @spec admin_measure(map()) :: map()
  def admin_measure(measure) do
    %{
      "key" => measure.key,
      "unit" => nil,
      "total" => measure.total,
      "human_value" => measure.total,
      "previous_total" => nil,
      "data" => Enum.map(measure.data, &%{"date" => day(&1.date), "value" => &1.value})
    }
  end

  @doc """
  One dimension.
  """
  @spec admin_dimension(map()) :: map()
  def admin_dimension(dimension) do
    %{
      "key" => dimension.key,
      "data" =>
        Enum.map(
          dimension.data,
          &%{"key" => &1.key, "human_key" => &1.human_key, "value" => &1.value}
        )
    }
  end

  @doc """
  One cohort's retention.
  """
  @spec admin_cohort(map()) :: map()
  def admin_cohort(cohort) do
    %{
      "period" => day(cohort.period),
      "frequency" => "day",
      "data" =>
        Enum.map(
          cohort.data,
          &%{"date" => day(&1.date), "rate" => &1.rate, "value" => to_string(&1.value)}
        )
    }
  end

  # Midnight UTC, which is what the reference implementation sends for a day.
  defp day(%Date{} = date), do: DateTime.to_iso8601(DateTime.new!(date, ~T[00:00:00], "Etc/UTC"))

  @doc """
  A domain this server has said yes to, on a server that says no by default.
  """
  @spec admin_domain_allow(map()) :: map()
  def admin_domain_allow(allow) do
    %{
      "id" => API.id(allow.id),
      "domain" => allow.domain,
      "created_at" => timestamp(allow.inserted_at)
    }
  end

  @doc """
  An email domain nobody may sign up with.

  `history` is what the reference implementation sends and what a moderation
  client renders as a sparkline. Empty here: nothing counts attempts per
  domain, and inventing numbers would be worse than saying there are none.
  """
  @spec admin_email_domain_block(map()) :: map()
  def admin_email_domain_block(block) do
    %{
      "id" => API.id(block.id),
      "domain" => block.domain,
      "created_at" => timestamp(block.inserted_at),
      "history" => []
    }
  end

  @doc """
  An address range, and what signing up from it costs.
  """
  @spec admin_ip_block(map()) :: map()
  def admin_ip_block(block) do
    %{
      "id" => API.id(block.id),
      "ip" => block.cidr,
      "severity" => block.severity,
      "comment" => block.comment || "",
      "created_at" => timestamp(block.inserted_at),
      "expires_at" => timestamp(block.expires_at)
    }
  end

  @doc """
  One address blocked by its canonical form.

  The hash and nothing else, deliberately: the whole point of storing the
  canonical form is that the address itself is not kept, and an entity that
  handed it back would undo that.
  """
  @spec admin_canonical_email_block(map()) :: map()
  def admin_canonical_email_block(block) do
    %{
      "id" => API.id(block.id),
      "canonical_email_hash" => block.canonical_email_hash
    }
  end

  @doc """
  One decision of this server's that cost somebody relationships.
  """
  @spec severance_event(map()) :: map()
  def severance_event(%{event: event, count: count}) do
    %{
      "id" => API.id(event.id),
      "type" => event.type,
      "purged" => event.purged,
      "target_name" => event.target_name,
      "relationships_count" => count,
      "created_at" => timestamp(event.inserted_at)
    }
  end

  defp notification_group(%{key: key, notifications: [newest | _] = notifications}, _viewer) do
    %{
      "group_key" => key,
      "notifications_count" => length(notifications),
      "type" => newest.type,
      "most_recent_notification_id" => API.id(newest.id),
      "page_min_id" => API.id(List.last(notifications).id),
      "page_max_id" => API.id(newest.id),
      "latest_page_notification_at" => timestamp(newest.inserted_at),
      "sample_account_ids" =>
        notifications |> Enum.take(8) |> Enum.map(&API.id(&1.from_account_id)) |> Enum.uniq(),
      "status_id" => API.id(newest.status_id)
    }
  end

  defp split_ungrouped(group, nil), do: [group]

  defp split_ungrouped(%{notifications: notifications} = group, grouped_types) do
    if hd(notifications).type in grouped_types do
      [group]
    else
      Enum.map(notifications, &%{key: "#{group.key}-#{&1.id}", notifications: [&1]})
    end
  end

  defp grouped_accounts(groups, viewer) do
    ids =
      groups
      |> Enum.flat_map(& &1.notifications)
      |> Enum.map(& &1.from_account_id)
      |> Enum.uniq()

    ids
    |> accounts_with_stats()
    |> Enum.map(fn {account, counters} -> rendered_account(account, viewer, counters) end)
  end

  defp grouped_statuses(groups, viewer) do
    ids =
      groups
      |> Enum.flat_map(& &1.notifications)
      |> Enum.map(& &1.status_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ids == [] do
      []
    else
      Statuses.not_deleted()
      |> Statuses.visible_to(viewer)
      |> where([s], s.id in ^ids)
      |> Repo.all()
      |> statuses(viewer)
    end
  end

  @doc """
  One upload, as a client renders it.

  `url` is `nil` while it is still being processed, which is what tells a
  client to show a placeholder rather than a broken picture.
  """
  @spec media_attachment(Attachment.t()) :: map()
  def media_attachment(%Attachment{} = attachment) do
    ready? = Attachment.ready?(attachment)
    url = attachment_url(attachment, ready?)
    # The small version where processing made one, which is the whole reason it
    # exists: a timeline of twenty posts should not fetch twenty full-size
    # photographs to show them at 400 pixels wide.
    preview = preview_url(attachment, ready?) || url

    %{
      "id" => API.id(attachment.id),
      "type" => to_string(attachment.type),
      "url" => url,
      "preview_url" => preview,
      "remote_url" =>
        if(attachment.remote_url in [nil, ""], do: nil, else: attachment.remote_url),
      "text_url" => nil,
      "description" => attachment.description,
      "blurhash" => attachment.blurhash,
      "meta" => attachment.meta || %{}
    }
  end

  # Another server's file goes through this one. A timeline of twenty posts
  # from twelve servers, rendered with the origin URLs, is twelve servers
  # learning the reader's address, their browser, and which posts they looked
  # at and when — none of which is any of their business, because the reader
  # chose to be here rather than there.
  #
  # `remote_url` still carries the original, because a client that wants to
  # know where a file really came from should be able to find out.
  defp attachment_url(%Attachment{remote_url: remote} = attachment, _ready?)
       when is_binary(remote) and remote != "" do
    URIs.base_url() <> "/media_proxy/#{attachment.id}/original"
  end

  defp attachment_url(attachment, true), do: Upload.url(attachment)
  defp attachment_url(_attachment, false), do: nil

  defp preview_url(%Attachment{remote_url: remote} = attachment, _ready?)
       when is_binary(remote) and remote != "" do
    URIs.base_url() <> "/media_proxy/#{attachment.id}/small"
  end

  defp preview_url(attachment, true), do: Upload.thumbnail_url(attachment)
  defp preview_url(_attachment, false), do: nil

  @doc """
  A list, as a client renders it.
  """
  @spec list(AccountList.t()) :: map()
  def list(%AccountList{} = list) do
    %{
      "id" => API.id(list.id),
      "title" => list.title,
      "replies_policy" => list.replies_policy,
      "exclusive" => list.exclusive
    }
  end

  @doc """
  A filter with the spellings it looks for.
  """
  @spec filter(Filter.t()) :: map()
  def filter(%Filter{} = filter) do
    %{
      "id" => API.id(filter.id),
      "title" => filter.title,
      "context" => filter.context,
      "filter_action" => filter.filter_action,
      "expires_at" => timestamp(filter.expires_at),
      "keywords" => Enum.map(loaded(filter.keywords), &filter_keyword/1),
      "statuses" => Enum.map(loaded(filter.statuses), &filter_status/1)
    }
  end

  @doc """
  One post a filter catches by name rather than by any word in it.
  """
  @spec filter_status(Abuuba.Filters.FilterStatus.t()) :: map()
  def filter_status(%Abuuba.Filters.FilterStatus{} = filter_status) do
    %{
      "id" => API.id(filter_status.id),
      "status_id" => API.id(filter_status.status_id)
    }
  end

  @doc """
  The older API's filter, which is one spelling wearing its rule's clothes.

  That API predates a rule being able to hold more than one keyword, so it has
  no word for the rule: the id names the keyword, `phrase` is the keyword, and
  everything else is read off the rule the keyword belongs to. A rule with two
  keywords therefore shows up as two filters, which is the honest answer to a
  client that cannot express the alternative.

  `irreversible` is the old spelling of `filter_action`. It was a boolean when
  there were two possible actions, and it survives as one.
  """
  @spec filter_v1(FilterKeyword.t()) :: map()
  def filter_v1(%FilterKeyword{filter: %Filter{} = filter} = keyword) do
    %{
      "id" => API.id(keyword.id),
      "phrase" => keyword.keyword,
      "context" => filter.context,
      "whole_word" => keyword.whole_word,
      "expires_at" => timestamp(filter.expires_at),
      "irreversible" => filter.filter_action == "hide"
    }
  end

  @doc """
  One spelling.
  """
  @spec filter_keyword(FilterKeyword.t()) :: map()
  def filter_keyword(%FilterKeyword{} = keyword) do
    %{
      "id" => API.id(keyword.id),
      "keyword" => keyword.keyword,
      "whole_word" => keyword.whole_word
    }
  end

  @doc """
  A conversation, as the direct-message column renders it.
  """
  @spec conversation(map(), Account.t() | nil) :: map()
  def conversation(row, viewer \\ nil) do
    [rendered] = conversations([row], viewer)

    rendered
  end

  @doc """
  A page of conversations, everybody named and every last post loaded once.

  The rows carry ids (`participant_account_ids`, `last_status_id`); rendering
  a page of twenty exchanges used to fetch and render each participant and
  each last post on its own.
  """
  @spec conversations([map()], Account.t() | nil) :: [map()]
  def conversations(rows, viewer \\ nil)
  def conversations([], _viewer), do: []

  def conversations(rows, viewer) do
    accounts =
      rows
      |> Enum.flat_map(&[&1[:account_id] | List.wrap(&1.participant_account_ids)])
      |> Enum.reject(&is_nil/1)
      |> rendered_accounts_by_id(viewer)

    statuses = statuses_by_id(Enum.map(rows, & &1.last_status_id), viewer)

    Enum.map(rows, fn row ->
      %{
        "id" => API.id(row.id),
        "unread" => row.unread,
        "accounts" => participants(row, accounts),
        "last_status" => row.last_status_id && statuses[to_string(row.last_status_id)]
      }
    end)
  end

  # A direct post that mentions nobody is a conversation with one person in it,
  # and that person is the one who wrote it. An empty list is what a client
  # draws the row from, so it showed an exchange with no name and no avatar --
  # a broken entry rather than a note somebody wrote to themselves. The
  # reference implementation falls back the same way.
  defp participants(row, accounts) do
    case row.participant_account_ids |> List.wrap() |> Enum.flat_map(&List.wrap(accounts[&1])) do
      [] -> List.wrap(accounts[row[:account_id]])
      rendered -> rendered
    end
  end

  defp loaded(%Ecto.Association.NotLoaded{}), do: []
  defp loaded(value) when is_list(value), do: value
  defp loaded(_value), do: []

  @doc """
  A hashtag, as a client renders it.
  """
  @spec tag(Tag.t(), Account.t() | nil) :: map()
  def tag(%Tag{} = tag, viewer \\ nil) do
    [rendered] = tags([tag], viewer)

    rendered
  end

  @doc """
  Several hashtags at once, the follow check batched.
  """
  @spec tags([Tag.t()], Account.t() | nil) :: [map()]
  def tags(tags, viewer \\ nil) do
    ids = Enum.map(tags, & &1.id)
    followed = Statuses.followed_tag_ids(viewer, ids)
    featured = Statuses.featured_tag_ids(viewer, ids)
    history = Trends.history("tag", Enum.map(tags, & &1.name))

    Enum.map(tags, fn tag ->
      %{
        "id" => API.id(tag.id),
        "name" => tag.display_name || tag.name,
        "url" => "#{URIs.base_url()}/tags/#{tag.name}",
        # A week of use, which is the graph beside a trending hashtag. This was
        # an empty list whatever the tag had done, so every one of them drew a
        # flat line -- while the counts behind it were being written all along,
        # because the trends screen is built on them.
        "history" => Enum.map(Map.get(history, tag.name, []), &history_day/1),
        "following" => MapSet.member?(followed, tag.id),
        # Following a hashtag and putting it on your profile are two different
        # things with two different controls, and only the first was answered.
        "featuring" => MapSet.member?(featured, tag.id)
      }
    end)
  end

  # Strings, all three of them, which is what the reference implementation
  # sends and therefore what clients parse.
  defp history_day(%{day: day, uses: uses, accounts: accounts}) do
    %{
      "day" => day |> DateTime.new!(~T[00:00:00]) |> DateTime.to_unix() |> to_string(),
      "uses" => to_string(uses),
      "accounts" => to_string(accounts)
    }
  end

  @doc """
  A custom emoji.
  """
  @spec custom_emoji(CustomEmoji.t()) :: map()
  def custom_emoji(%CustomEmoji{} = emoji) do
    %{
      "shortcode" => emoji.shortcode,
      "url" => emoji.image_url,
      "static_url" => emoji.static_url || emoji.image_url,
      "visible_in_picker" => emoji.visible_in_picker,
      "category" => emoji.category
    }
  end

  @doc """
  A server announcement, with how this reader has reacted to it.
  """
  @spec announcement(Announcement.t(), Account.t() | nil) :: map()
  def announcement(%Announcement{} = announcement, viewer \\ nil) do
    %{
      "id" => API.id(announcement.id),
      "content" => announcement.text,
      "starts_at" => timestamp(announcement.starts_at),
      "ends_at" => timestamp(announcement.ends_at),
      "all_day" => announcement.all_day,
      "published_at" => timestamp(announcement.published_at),
      "updated_at" => timestamp(announcement.updated_at),
      "read" => Instance.announcement_read?(announcement, viewer),
      "mentions" => [],
      "statuses" => [],
      "tags" => [],
      "emojis" => [],
      "reactions" =>
        announcement
        |> Instance.announcement_reactions(viewer)
        |> Enum.map(&%{"name" => &1.name, "count" => &1.count, "me" => &1.me})
    }
  end

  @doc """
  One of the server's rules.
  """
  @spec rule(map()) :: map()
  def rule(rule) do
    %{
      "id" => API.id(Map.get(rule, :id)),
      "text" => Map.get(rule, :text) || "",
      "hint" => Map.get(rule, :hint) || ""
    }
  end

  @doc """
  One version of the terms of service.
  """
  @spec terms_of_service(map()) :: map()
  def terms_of_service(terms) do
    %{
      "effective_date" => to_string(terms.effective_date),
      "content" => terms.text,
      "succeeded_by" => nil
    }
  end

  @doc """
  An invite, as whoever wrote it reads it back.
  """
  @spec invite(map()) :: map()
  def invite(invite) do
    %{
      "id" => API.id(invite.id),
      "code" => invite.code,
      "comment" => invite.comment,
      "url" => "#{URIs.base_url()}/register?invite=#{invite.code}",
      "created_at" => timestamp(invite.inserted_at),
      "expires_at" => timestamp(invite.expires_at),
      "max_uses" => invite.max_uses,
      "uses" => invite.uses,
      "autofollow" => invite.autofollow,
      "expired" => Invite.expired?(invite, DateTime.utc_now()),
      "used_up" => Invite.used_up?(invite)
    }
  end

  @doc """
  A push subscription, as a client reads it back.

  The server's VAPID public key travels with it, because a browser has to know
  it before it can subscribe and a subscription made against one key cannot be
  pushed to with another.
  """
  @spec push_subscription(Subscription.t()) :: map()
  def push_subscription(%Subscription{} = subscription) do
    %{
      "id" => API.id(subscription.id),
      "endpoint" => subscription.endpoint,
      "alerts" => subscription.alerts,
      "policy" => subscription.policy,
      "server_key" => VAPID.public_key()
    }
  end
end
