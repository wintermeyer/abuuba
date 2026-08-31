defmodule Abuuba.Trends do
  @moduledoc """
  What is being used more than usual, and what a moderator has said about it.

  ## Counted in people, not in posts

  A trend is a number of people, so the score is built from how many distinct
  accounts used something rather than how many times it was used. One person
  posting a tag two hundred times is one person shouting, and a score built on
  uses would put them on the front page.

  Counts live in Postgres, one row per subject per day plus one narrow row per
  participating account. Counting distinct people exactly costs a row each and
  can be audited afterwards, which an approximation cannot; the rows are swept,
  so the tables stay the size of what is happening now.

  ## The score

      (observed - expected)^2 / expected

  `expected` is yesterday's number of people and `observed` is today's, so
  something used as much as it was yesterday scores zero however popular it is.
  A tag ten people use every day is the server's furniture, not news. The
  squared difference is what makes a jump from two to forty worth far more than
  a nudge from two to four.

  The result then decays by a half-life that depends on what it is. A post is
  interesting for an hour, a tag for an afternoon, a link for most of a day.
  One half-life for all three would be wrong twice.

  ## Nothing is shown before somebody has looked at it

  Every subject carries three states: approved, rejected, and nobody has looked
  yet. The trending list is the most prominent place on a server, and handing
  it to whatever an anonymous crowd pushed hardest is how it becomes a
  megaphone for the thing being pushed. What an unreviewed subject does is the
  `trendable_by_default` setting's business, and the queue of them is what the
  people holding `manage_taxonomies` are told about.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.User
  alias Abuuba.Federation.InstanceActor
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Notifications
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Settings
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Formatter
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.Tag
  alias Abuuba.Timelines
  alias Abuuba.Trends.Link
  alias Abuuba.Trends.Trend

  @kinds ~w(tag link status)

  # How long each kind stays interesting. A post is an hour, a tag an
  # afternoon, a link most of a working day.
  @half_lives %{"status" => 1, "tag" => 4, "link" => 8}

  # Two days of counts: today is `observed`, yesterday is `expected`, and
  # everything older has already done its job.
  @keep_days 2

  # How many of each kind a ranking keeps. Beyond this nobody scrolls, and the
  # tail is where the noise is.
  @rank_limit 50

  @doc "Every kind of thing that can trend."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "How long a kind's score takes to halve, in hours."
  @spec half_life_hours(String.t()) :: pos_integer()
  def half_life_hours(kind), do: Map.get(@half_lives, kind, 4)

  ## Counting

  @doc """
  Records what one post contributes: its tags and its links.

  Not the post itself. A post trends on the attention it gets rather than on
  having been written, or every post on the server would start at one person
  and the newest would always be the trend.

  Everything ineligible is dropped here rather than filtered at ranking time,
  so a post that should never have counted leaves no trace to forget about.
  """
  @spec record_status(Status.t()) :: :ok
  def record_status(%Status{} = status) do
    if eligible?(status) do
      day = Date.utc_today()

      for tag <- Formatter.hashtags(status.text) do
        add("tag", tag, status.account_id, day, status.language)
      end

      for url <- urls(status.text) do
        record_link(url)
        add("link", url, status.account_id, day, status.language)
      end
    end

    :ok
  end

  @doc """
  Records that a post shared a link.

  Called when a preview card is attached rather than when the text is written:
  a link nobody attached to a post is a link nobody shared, and a card is what
  says the link was really a link rather than an address in a sentence.
  """
  @spec record_link(Status.t(), String.t()) :: :ok
  def record_link(%Status{} = status, url) do
    if eligible?(status) do
      # The row as well as the count. It is where a decision about this link
      # and its publisher lives, and writing it only when somebody reviews one
      # meant a moderator could not see a publisher until after deciding about
      # it — which is the wrong way round.
      record_link(url)
      add("link", url, status.account_id, Date.utc_today(), status.language)
    end

    :ok
  end

  @doc """
  Records somebody paying attention to a post: a favourite, a boost, a reply
  from elsewhere.

  Attention is what makes a post trend, rather than the author's own act of
  writing it.
  """
  @spec record_interaction(Status.t() | integer(), Account.t() | integer()) :: :ok
  def record_interaction(%Status{} = status, account) do
    if eligible?(status) do
      add("status", to_string(status.id), account_id(account), Date.utc_today(), status.language)
    end

    :ok
  end

  def record_interaction(status_id, account) do
    case Repo.get(Status, status_id) do
      nil -> :ok
      status -> record_interaction(status, account)
    end
  end

  @doc """
  How much a subject was used on a day, and by how many people.
  """
  @spec counts(String.t(), String.t(), Date.t()) :: %{uses: integer(), accounts: integer()}
  def counts(kind, subject, day \\ nil) do
    day = day || Date.utc_today()

    from(c in "trend_counters",
      where: c.kind == ^kind and c.subject == ^normalise(kind, subject) and c.day == ^day,
      select: %{uses: c.uses, accounts: c.accounts}
    )
    |> Repo.one()
    |> case do
      nil -> %{uses: 0, accounts: 0}
      row -> row
    end
  end

  @doc """
  The last `days` of counts for each of `subjects`, newest day first.

  One query for the whole page rather than one per subject per day, because
  this renders behind every list of hashtags there is. Days nobody used a
  subject come back as zeroes rather than as gaps: the shape a client draws is
  a fixed-length series, and a missing day would shift the graph.
  """
  @spec history(String.t(), [String.t()], pos_integer()) :: %{String.t() => [map()]}
  def history(kind, subjects, days \\ 7)
  def history(_kind, [], _days), do: %{}

  def history(kind, subjects, days) do
    today = Date.utc_today()
    span = Enum.map(0..(days - 1), &Date.add(today, -&1))
    oldest = List.last(span)
    normalised = Map.new(subjects, &{normalise(kind, &1), &1})

    stored =
      from(c in "trend_counters",
        where: c.kind == ^kind and c.subject in ^Map.keys(normalised) and c.day >= ^oldest,
        select: {c.subject, c.day, c.uses, c.accounts}
      )
      |> Repo.all()
      |> Map.new(fn {subject, day, uses, accounts} ->
        {{subject, day}, %{uses: uses, accounts: accounts}}
      end)

    Map.new(normalised, fn {normalised_subject, subject} ->
      {subject,
       Enum.map(span, fn day ->
         counts = Map.get(stored, {normalised_subject, day}, %{uses: 0, accounts: 0})

         %{day: day, uses: counts.uses, accounts: counts.accounts}
       end)}
    end)
  end

  @doc """
  Sets counts directly. For seeding a state that would otherwise take a day of
  real traffic to reach.
  """
  @spec put_counts(String.t(), String.t(), Date.t(), keyword()) :: :ok
  def put_counts(kind, subject, day, opts) do
    accounts = Keyword.get(opts, :accounts, 0)
    uses = Keyword.get(opts, :uses, accounts)

    write_counter(kind, normalise(kind, subject), day,
      uses: uses,
      accounts: accounts,
      language: Keyword.get(opts, :language)
    )

    :ok
  end

  ## Scoring

  @doc """
  How much more a subject is being used than it was yesterday.
  """
  @spec score(String.t(), String.t()) :: float()
  def score(kind, subject) do
    today = counts(kind, subject).accounts
    yesterday = counts(kind, subject, Date.add(Date.utc_today(), -1)).accounts

    raw_score(today, yesterday)
  end

  @doc """
  The formula, given today's and yesterday's numbers of people.

  Zero when a subject is no busier than it was: steady use is not a trend.
  """
  @spec raw_score(number(), number()) :: float()
  def raw_score(observed, expected) do
    expected = max(expected, 1)

    if observed > expected do
      (observed - expected) ** 2 / expected
    else
      0.0
    end
  end

  @doc """
  What a score is worth after some hours have passed.
  """
  @spec decay(float(), number(), String.t()) :: float()
  def decay(score, hours, kind), do: score * 0.5 ** (hours / half_life_hours(kind))

  ## Ranking

  @doc """
  Rewrites the rankings from the current counts.

  Rewritten rather than maintained: keeping a running rank correct under
  concurrent writes is far harder than recomputing a few hundred rows, and a
  rank five minutes stale is not a problem anybody has.
  """
  @spec rank() :: :ok
  def rank do
    # One question first: has anything been counted today at all? This runs on
    # a timer whether or not anybody has posted, and without it a server nobody
    # has used yet spent eighteen queries every five minutes to rank nothing —
    # all of them logged in development, which is a console filling with trend
    # queries shortly after somebody first started the thing.
    if counted_today?() do
      rank_counted()
    else
      forget_ranking()
    end

    :ok
  end

  defp rank_counted do
    default = trendable_by_default?()

    rows =
      @kinds
      |> Enum.flat_map(&ranked_rows(&1, default))
      |> Enum.map(&Map.put(&1, :inserted_at, DateTime.utc_now()))
      |> Enum.map(&Map.put(&1, :updated_at, DateTime.utc_now()))

    Repo.transaction(fn ->
      Repo.delete_all(Trend)
      if rows != [], do: Repo.insert_all(Trend, rows)
    end)

    request_reviews()
  end

  defp counted_today?(day \\ Date.utc_today()) do
    from(c in "trend_counters", where: c.day == ^day, select: 1, limit: 1) |> Repo.exists?()
  end

  # Yesterday's ranking outlives the day it was computed for, so a server that
  # went quiet has to be told to stop showing it. Checked before deleting,
  # because on a server that has never trended anything there is nothing to
  # delete and the check is the cheaper of the two.
  defp forget_ranking do
    if Repo.exists?(Trend), do: Repo.delete_all(Trend)
  end

  @doc """
  The current ranking for one kind, best first.
  """
  @spec list(String.t(), keyword()) :: [Trend.t()]
  def list(kind, opts \\ []) do
    Trend
    |> where([t], t.kind == ^kind)
    |> filter_language(Keyword.get(opts, :language, :any))
    |> order_by([t], asc: t.rank)
    |> limit(^Keyword.get(opts, :limit, @rank_limit))
    |> Repo.all()
  end

  defp filter_language(query, :any), do: query
  defp filter_language(query, nil), do: where(query, [t], is_nil(t.language))
  defp filter_language(query, language), do: where(query, [t], t.language == ^language)

  @doc """
  The posts trending right now, as this reader may be shown them.

  `list/2` answers with rows of a ranking table, which knows what is busy and
  nothing about who is asking. Handing those subjects straight to a caller
  made trending the one door into the public timelines that asked nothing at
  all -- not `timeline_access`, and not the reader's own blocks and mutes
  either, so `eligible?/1` at write time was the whole of the check.

  Both are asked here rather than by the caller, through the same
  `Abuuba.Timelines` the public timeline goes through. A ranking is not a
  reason to show somebody a post they have said they do not want.
  """
  @spec statuses(Account.t() | nil, keyword()) :: [Status.t()]
  def statuses(viewer, opts \\ []) do
    if Settings.public_timelines_readable?(viewer) do
      "status" |> list(opts) |> Enum.map(& &1.subject) |> Timelines.by_ids(viewer)
    else
      []
    end
  end

  @doc """
  The hashtags trending right now, as this reader may be shown them.

  Behind the same setting as `statuses/2`, because a trend is a summary of the
  timeline rather than a thing apart: a tag entity carries how many people
  used it on each of the last seven days, all of it counted from the posts a
  server set to `authenticated` has just refused to show. A front page
  advertising `#outdoors` and a `/tags/outdoors` that answers nothing is the
  setting saying one thing and the door doing another.
  """
  @spec tags(Account.t() | nil, keyword()) :: [Tag.t()]
  def tags(viewer, opts \\ []) do
    if Settings.public_timelines_readable?(viewer) do
      "tag" |> list(opts) |> Enum.map(& &1.subject) |> Statuses.get_tags()
    else
      []
    end
  end

  @doc """
  The links trending right now, as this reader may be shown them.

  Same setting, same reason as `tags/2`: a link trends because of the posts
  that carried it. Named the long way because `links/1` is already the
  moderation listing of every link this server has seen.
  """
  @spec trending_links(Account.t() | nil, keyword()) :: [Trend.t()]
  def trending_links(viewer, opts \\ []) do
    if Settings.public_timelines_readable?(viewer), do: list("link", opts), else: []
  end

  ## Review

  @doc """
  Subjects that are busy enough to show and that nobody has looked at.
  """
  @spec pending_reviews(String.t() | nil) :: [%{kind: String.t(), subject: String.t()}]
  def pending_reviews(kind \\ nil) do
    kinds = if kind, do: [kind], else: @kinds

    Enum.flat_map(kinds, fn kind ->
      kind
      |> busy_subjects()
      |> Enum.filter(&(trendable_state(kind, &1) == :unreviewed))
      |> Enum.map(&%{kind: kind, subject: &1})
    end)
  end

  @doc """
  Lets a subject appear in the trending lists.
  """
  @spec approve(Account.t(), String.t(), String.t()) :: :ok
  def approve(%Account{} = moderator, kind, subject), do: review(moderator, kind, subject, true)

  @doc """
  Keeps a subject out of them for good.
  """
  @spec reject(Account.t(), String.t(), String.t()) :: :ok
  def reject(%Account{} = moderator, kind, subject), do: review(moderator, kind, subject, false)

  @doc """
  Every publisher whose links have trended, with what a moderator decided.

  A publisher rather than a link: deciding about one article from a site says
  nothing about the next one, and deciding about the site is the decision a
  moderator actually wants to make.
  """
  @spec providers(map()) :: [map()]
  def providers(page \\ %{}) do
    from(l in Link,
      where: not is_nil(l.provider) and l.provider != "",
      group_by: l.provider,
      order_by: [desc: max(l.id)],
      limit: ^Map.get(page, :limit, 40),
      select: %{
        provider: l.provider,
        # Reviewing a publisher decides every link it has, so the publisher's
        # answer is what its links agree on. `bool_and` over a nullable column
        # is null when nobody has decided anything, which is the third answer
        # and not the same as "no".
        trendable: fragment("bool_and(?)", l.trendable),
        reviewed_at: max(l.reviewed_at)
      }
    )
    |> Repo.all()
  end

  @doc """
  Decides about every link from one site at once.

  A news site posting forty stories a day is one judgement, not forty.
  """
  @spec approve_provider(Account.t(), String.t()) :: :ok
  def approve_provider(moderator, provider), do: review_provider(moderator, provider, true)

  @doc "Keeps every link from one site out of the trending lists."
  @spec reject_provider(Account.t(), String.t()) :: :ok
  def reject_provider(moderator, provider), do: review_provider(moderator, provider, false)

  @doc """
  Decides whether one account's posts may trend at all.
  """
  @spec approve_author(Account.t(), Account.t()) :: :ok
  def approve_author(moderator, author), do: review_author(moderator, author, true)

  @doc "Keeps one account's posts out of the trending lists."
  @spec reject_author(Account.t(), Account.t()) :: :ok
  def reject_author(moderator, author), do: review_author(moderator, author, false)

  @doc """
  Every link this server has seen in a public post.
  """
  @spec links(map()) :: [Link.t()]
  def links(page \\ %{}) do
    Link
    |> order_by([l], desc: l.id)
    |> limit(^Map.get(page, :limit, 100))
    |> Repo.all()
  end

  @doc """
  Whether a subject nobody has reviewed may be shown.
  """
  @spec trendable_by_default?() :: boolean()
  def trendable_by_default?, do: Settings.get("trendable_by_default") == true

  ## Sweeping

  @doc """
  Throws away counts too old to be part of any score.
  """
  @spec sweep() :: :ok
  def sweep do
    cutoff = Date.add(Date.utc_today(), -(@keep_days - 1))

    Repo.delete_all(from(c in "trend_counters", where: c.day < ^cutoff))
    Repo.delete_all(from(p in "trend_participants", where: p.day < ^cutoff))

    :ok
  end

  ## Eligibility

  @doc """
  Whether a post may contribute to trends at all.

  Public, from somebody who asked to be findable, not sensitive, and not a
  reply. A conversation is not a trend, and counting replies makes the loudest
  argument on the server the thing everybody is shown.
  """
  @spec eligible?(Status.t()) :: boolean()
  def eligible?(%Status{} = status) do
    status.visibility == :public and
      is_nil(status.in_reply_to_id) and
      not status.sensitive and
      is_nil(status.deleted_at) and
      author_eligible?(status.account_id)
  end

  def eligible?(_status), do: false

  defp author_eligible?(account_id) do
    case Repo.get(Account, account_id) do
      nil ->
        false

      account ->
        account.discoverable and is_nil(account.silenced_at) and is_nil(account.suspended_at) and
          account.trendable != false
    end
  end

  ## Counting, inside

  # The participant row is the question "have we already counted this person
  # today"; the answer decides whether the distinct-account number moves. One
  # insert and one upsert per use, and no group-by anywhere near the ranking.
  defp add(kind, subject, account_id, day, language) do
    subject = normalise(kind, subject)

    {inserted, _} =
      Repo.insert_all(
        "trend_participants",
        [[kind: kind, subject: subject, day: day, account_id: account_id]],
        on_conflict: :nothing
      )

    bump_counter(kind, subject, day, language, inserted)

    inserted
  end

  defp normalise("tag", subject), do: String.downcase(subject)
  defp normalise(_kind, subject), do: subject

  defp bump_counter(kind, subject, day, language, new_accounts) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "trend_counters",
      [
        [
          kind: kind,
          subject: subject,
          day: day,
          uses: 1,
          accounts: new_accounts,
          language: language,
          inserted_at: now,
          updated_at: now
        ]
      ],
      conflict_target: [:kind, :subject, :day],
      on_conflict:
        from(c in "trend_counters",
          update: [inc: [uses: 1, accounts: ^new_accounts], set: [updated_at: ^now]]
        )
    )
  end

  defp write_counter(kind, subject, day, fields) do
    now = DateTime.utc_now()
    uses = Keyword.fetch!(fields, :uses)
    accounts = Keyword.fetch!(fields, :accounts)

    Repo.insert_all(
      "trend_counters",
      [
        [
          kind: kind,
          subject: subject,
          day: day,
          uses: uses,
          accounts: accounts,
          language: Keyword.get(fields, :language),
          inserted_at: now,
          updated_at: now
        ]
      ],
      conflict_target: [:kind, :subject, :day],
      on_conflict:
        from(c in "trend_counters",
          update: [set: [uses: ^uses, accounts: ^accounts, updated_at: ^now]]
        )
    )
  end

  # Bare hyperlinks, which is what a post carries before preview cards exist.
  # The fragment is dropped so that one article shared with three different
  # anchors is one link.
  defp urls(nil), do: []

  defp urls(text) do
    ~r{https?://[^\s<>"']+}
    |> Regex.scan(text)
    |> Enum.map(fn [url] -> url |> String.trim_trailing(".") |> strip_fragment() end)
    |> Enum.uniq()
  end

  defp strip_fragment(url), do: url |> String.split("#", parts: 2) |> hd()

  defp record_link(url) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Link,
      [
        [
          url: url,
          provider: provider_of(url),
          inserted_at: now,
          updated_at: now
        ]
      ],
      conflict_target: [:url],
      on_conflict: :nothing
    )
  end

  defp provider_of(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _ -> ""
    end
  end

  ## Ranking, inside

  defp ranked_rows(kind, default) do
    today = Date.utc_today()

    # Today's counters first, and nothing else if there are none. Ranking runs
    # on a timer whether or not anybody has posted, so on a quiet server every
    # query after this one is asked about the empty set — and in development
    # each is logged, which is a console filling with trend queries five
    # minutes after somebody first started the thing.
    case rows_for(kind, today) do
      [] -> []
      rows -> ranked_rows(kind, default, rows, account_counts(kind, Date.add(today, -1)))
    end
  end

  defp ranked_rows(kind, default, rows, yesterdays) do
    rows
    |> Enum.map(fn row ->
      %{
        kind: kind,
        subject: row.subject,
        language: row.language,
        score: raw_score(row.accounts, Map.get(yesterdays, row.subject, 0)),
        uses: row.uses,
        accounts: row.accounts
      }
    end)
    |> Enum.filter(&(&1.score > 0 and showable?(kind, &1.subject, default)))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(@rank_limit)
    |> Enum.with_index(1)
    |> Enum.map(fn {row, index} -> Map.put(row, :rank, index) end)
  end

  defp rows_for(kind, day) do
    from(c in "trend_counters",
      where: c.kind == ^kind and c.day == ^day,
      select: %{subject: c.subject, uses: c.uses, accounts: c.accounts, language: c.language}
    )
    |> Repo.all()
  end

  defp account_counts(kind, day) do
    from(c in "trend_counters",
      where: c.kind == ^kind and c.day == ^day,
      select: {c.subject, c.accounts}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Busy enough that somebody would see it if it were shown. The review queue
  # is what is waiting to be looked at, not every tag anybody ever typed.
  defp busy_subjects(kind) do
    today = Date.utc_today()

    # Same short circuit as `ranked_rows/2`, for the same reason: no counters
    # today means nothing is busy, and asking about yesterday cannot change it.
    case account_counts(kind, today) do
      counts when map_size(counts) == 0 ->
        []

      counts ->
        yesterdays = account_counts(kind, Date.add(today, -1))

        counts
        |> Enum.filter(fn {subject, observed} ->
          raw_score(observed, Map.get(yesterdays, subject, 0)) > 0
        end)
        |> Enum.map(&elem(&1, 0))
    end
  end

  defp showable?(kind, subject, default) do
    case trendable_state(kind, subject) do
      :approved -> true
      :rejected -> false
      :unreviewed -> default
    end
  end

  defp trendable_state("tag", subject) do
    case Repo.get_by(Tag, name: String.downcase(subject)) do
      nil -> :unreviewed
      %Tag{trendable: nil} -> :unreviewed
      %Tag{trendable: true} -> :approved
      _tag -> :rejected
    end
  end

  defp trendable_state("link", url) do
    case Repo.get_by(Link, url: url) do
      nil -> :unreviewed
      %Link{trendable: nil} -> :unreviewed
      %Link{trendable: true} -> :approved
      _link -> :rejected
    end
  end

  # A post is shown on the author's say-so rather than its own. Reviewing every
  # post one at a time is a queue nobody can keep up with, and the judgement
  # being made is about who wrote it.
  defp trendable_state("status", id) do
    with {number, ""} <- Integer.parse(id),
         %Status{} = status <- Repo.get(Status, number),
         %Account{} = author <- Repo.get(Account, status.account_id) do
      case author.trendable do
        nil -> :unreviewed
        true -> :approved
        false -> :rejected
      end
    else
      _ -> :rejected
    end
  end

  ## Review, inside

  defp review(moderator, kind, subject, allowed) do
    apply_review(kind, subject, allowed)

    AuditLog.record(moderator, "trend.#{verb(allowed)}", :trend, 0, %{
      "kind" => kind,
      "subject" => subject,
      "label" => "#{kind} #{subject}"
    })

    :ok
  end

  defp verb(true), do: "approve"
  defp verb(false), do: "reject"

  defp apply_review("tag", subject, allowed) do
    now = DateTime.utc_now()

    from(t in Tag, where: t.name == ^String.downcase(subject))
    |> Repo.update_all(set: [trendable: allowed, reviewed_at: now, updated_at: now])
  end

  defp apply_review("link", url, allowed) do
    now = DateTime.utc_now()

    # Recorded even for a URL with no row yet. A decision taken about something
    # this server has not seen is still a decision, and losing it would mean
    # asking the same moderator the same question the first time it appears.
    record_link(url)

    from(l in Link, where: l.url == ^url)
    |> Repo.update_all(set: [trendable: allowed, reviewed_at: now, updated_at: now])
  end

  defp apply_review("status", id, allowed) do
    with {number, ""} <- Integer.parse(id),
         %Status{} = status <- Repo.get(Status, number) do
      set_author_trendable(status.account_id, allowed)
    end
  end

  defp review_provider(moderator, provider, allowed) do
    now = DateTime.utc_now()

    from(l in Link, where: l.provider == ^String.downcase(provider))
    |> Repo.update_all(set: [trendable: allowed, reviewed_at: now, updated_at: now])

    AuditLog.record(moderator, "trend.#{verb(allowed)}_provider", :trend, 0, %{
      "provider" => provider,
      "label" => provider
    })

    :ok
  end

  defp review_author(moderator, author, allowed) do
    set_author_trendable(account_id(author), allowed)

    AuditLog.record(moderator, "trend.#{verb(allowed)}_author", :account, account_id(author))

    :ok
  end

  defp set_author_trendable(account_id, allowed) do
    now = DateTime.utc_now()

    from(a in Account, where: a.id == ^account_id)
    |> Repo.update_all(set: [trendable: allowed, updated_at: now])
  end

  # Told once about each subject, not once per recompute. The ranking runs
  # every five minutes, and a notification each time would turn one busy tag
  # into a hundred and forty a day.
  defp request_reviews do
    pending = pending_reviews()

    if pending != [] do
      now = DateTime.utc_now()
      # The server noticed this, not a person, so the notification comes from
      # the instance actor. Fetched once: it is the same actor for everybody.
      from_id = InstanceActor.fetch!().id
      reviewers = reviewers()

      for %{kind: kind, subject: subject} <- pending,
          mark_requested(kind, subject, now),
          account_id <- reviewers do
        Notifications.notify(account_id, from_id, "admin.report")
      end
    end

    :ok
  end

  defp mark_requested("tag", subject, now) do
    {count, _} =
      from(t in Tag, where: t.name == ^String.downcase(subject) and is_nil(t.requested_review_at))
      |> Repo.update_all(set: [requested_review_at: now, updated_at: now])

    count > 0
  end

  defp mark_requested("link", url, now) do
    {count, _} =
      from(l in Link, where: l.url == ^url and is_nil(l.requested_review_at))
      |> Repo.update_all(set: [requested_review_at: now, updated_at: now])

    count > 0
  end

  # A post's reviewability is its author's, and an author asked about once has
  # been asked about.
  defp mark_requested("status", _id, _now), do: false

  defp reviewers do
    from(u in "users",
      join: r in "user_roles",
      on: r.id == u.role_id,
      select: u.account_id
    )
    |> Repo.all()
    |> Enum.filter(fn account_id ->
      case Repo.get_by(User, account_id: account_id) do
        nil -> false
        user -> Roles.can?(user, "manage_taxonomies")
      end
    end)
  end

  ## Plumbing

  defp account_id(%Account{id: id}), do: id
  defp account_id(id) when is_integer(id), do: id
end
