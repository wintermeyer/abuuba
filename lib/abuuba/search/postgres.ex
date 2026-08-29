defmodule Abuuba.Search.Postgres do
  @moduledoc """
  Search in the database this server already runs.

  ## No second datastore

  A search cluster is another process to run, another thing to keep in step
  with the truth, and another way for the two to disagree. Postgres full text
  is enough for a server of the size abuuba is built for, and the behaviour above
  this module is what lets somebody who has outgrown it slot in something else.

  ## `simple`, not a dictionary

  A dictionary stems words in one language. A fediverse timeline is many at
  once, and stemming German with English rules turns real words into ones
  nobody typed. `simple` folds case and splits on punctuation, which is right
  far more often than any single dictionary would be.

  ## `websearch_to_tsquery`, not a parser of our own

  It already understands quoted phrases, `or`, and a leading minus, and it
  never raises on punctuation somebody typed. Hand-rolling that would be a
  parser to maintain and a syntax error waiting for the first person who types
  an ampersand.

  ## The ACL is a join, not a denormalised array

  A status is searchable by the person who wrote it, anybody it mentions, and
  anybody who kept it: favourited, boosted or bookmarked. The reference
  implementation stores that as an array on the row and rewrites it on every
  favourite, which means a popular post is re-indexed thousands of times. The
  same rule expressed as a set of joins at query time costs a little more per
  search and nothing at all per favourite, and searches are far rarer than
  favourites.
  """

  @behaviour Abuuba.Search

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Relationships.Follow
  alias Abuuba.Repo
  alias Abuuba.Search.Query
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Bookmark
  alias Abuuba.Statuses.Favourite
  alias Abuuba.Statuses.Mention
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.Tag

  # Trigram similarity below this is noise. Low enough that half a name still
  # matches, high enough that two unrelated names do not.
  @similarity 0.2

  @impl Abuuba.Search
  def statuses(%Query{} = query, viewer, opts) do
    Statuses.not_deleted()
    |> scope(query, viewer)
    # What the reader may read, and then who they are on speaking terms with.
    # Every timeline asked both; this asked only the first, so a blocked reader
    # could find the blocker's posts by typing a word from one.
    |> Statuses.excluding_hidden(viewer)
    |> match(query)
    |> narrow(query)
    |> maybe_author(opts)
    |> order_by([s], desc: s.id)
    |> limit(^Keyword.get(opts, :limit, 20))
    |> offset(^Keyword.get(opts, :offset, 0))
    |> Repo.all()
  end

  @impl Abuuba.Search
  def accounts(%Query{} = query, viewer, opts) do
    term = query.text

    # The stats join feeds the rank: a joined row is one hash lookup for the
    # whole candidate set, where a correlated subquery in the rank expression
    # was one index probe per matching row before the sort.
    Account
    |> where([a], is_nil(a.suspended_at))
    # Not an account somebody has moved away from: the one they moved to is
    # what a search is for, and offering the old one sends people to an account
    # that will never answer. Limited accounts are still findable, deliberately
    # and as upstream -- being limited is about not being offered unasked,
    # which a search is not.
    |> where([a], is_nil(a.moved_to_account_id))
    |> where([a], ^match_account(term))
    |> join(:left, [a], st in "account_stats", on: st.account_id == a.id)
    |> maybe_domain(query)
    |> maybe_local(opts)
    |> maybe_followed_by(opts)
    |> order_by(^[desc: rank_account(term, viewer)])
    |> limit(^Keyword.get(opts, :limit, 40))
    |> select([a, _st], a)
    |> Repo.all()
  end

  @impl Abuuba.Search
  def tags(%Query{} = query, _viewer, opts) do
    term = Tag.normalise(String.trim_leading(query.text, "#"))

    if term == "" do
      []
    else
      Tag
      |> where([t], t.listable)
      |> maybe_reviewed(opts)
      |> where(
        [t],
        t.name == ^term or fragment("similarity(lower(?), ?) > ?", t.name, ^term, ^@similarity)
      )
      # Exact first, then by how close the rest are, then by length so the
      # shortest of two equally close names wins.
      |> order_by([t],
        desc: fragment("(? = ?)", t.name, ^term),
        desc: fragment("similarity(lower(?), ?)", t.name, ^term),
        asc: fragment("length(?)", t.name)
      )
      |> limit(^Keyword.get(opts, :limit, 20))
      |> Repo.all()
    end
  end

  ## Statuses

  # Who may find a post, which is a stricter question than who may read one: a
  # public post nobody has interacted with is findable by everybody, and
  # anything narrower is findable only by the people it belongs to.
  defp scope(base, %Query{operators: %{in: "public"}}, viewer) do
    base
    |> Statuses.visible_to(viewer)
    |> where([s], s.visibility in [:public, :unlisted])
  end

  defp scope(base, %Query{operators: %{in: "library"}}, viewer) do
    base |> Statuses.visible_to(viewer) |> where(^own_library(viewer))
  end

  defp scope(base, _query, nil) do
    base |> Statuses.visible_to(nil) |> where([s], s.visibility in [:public, :unlisted])
  end

  # The default is both: what anybody may read, plus what this reader kept even
  # where it was addressed narrowly.
  defp scope(base, _query, viewer) do
    base |> Statuses.visible_to(viewer) |> where(^findable_by(viewer))
  end

  # Built as one dynamic rather than an expression with a dynamic inside it:
  # Ecto composes dynamics with each other, not with a literal `or`.
  defp findable_by(viewer) do
    library = own_library(viewer)

    dynamic([s], s.visibility in [:public, :unlisted] or ^library)
  end

  defp own_library(nil), do: dynamic([s], false)

  defp own_library(%Account{id: id}), do: own_library(id)

  defp own_library(viewer_id) do
    mentioned = from(m in Mention, where: m.account_id == ^viewer_id, select: m.status_id)
    favourited = from(f in Favourite, where: f.account_id == ^viewer_id, select: f.status_id)
    bookmarked = from(b in Bookmark, where: b.account_id == ^viewer_id, select: b.status_id)
    boosted = from(s in Status, where: s.account_id == ^viewer_id, select: s.reblog_of_id)

    dynamic(
      [s],
      s.account_id == ^viewer_id or
        s.id in subquery(mentioned) or
        s.id in subquery(favourited) or
        s.id in subquery(bookmarked) or
        s.id in subquery(boosted)
    )
  end

  defp match(query, %Query{text: ""}), do: query

  defp match(query, %Query{text: text}) do
    where(query, [s], fragment("? @@ websearch_to_tsquery('simple', ?)", s.searchable, ^text))
  end

  # `account_id` on the request, which is what an app sends for "search within
  # this profile". The same narrowing the `from:` operator does, reached by a
  # parameter rather than by the query text.
  defp maybe_author(query, opts) do
    case Keyword.get(opts, :account_id) do
      nil -> query
      id -> where(query, [s], s.account_id == ^id)
    end
  end

  # `following=true`, which asks for the people somebody already knows rather
  # than everybody who happens to match.
  defp maybe_followed_by(query, opts) do
    case Keyword.get(opts, :followed_by) do
      nil ->
        query

      viewer_id ->
        join(query, :inner, [a], f in "follows",
          on: f.target_account_id == a.id and f.account_id == ^viewer_id
        )
    end
  end

  # `exclude_unreviewed=true`. `reviewed_at` is nullable precisely so that null
  # means nobody has looked yet, which is the set this leaves out.
  defp maybe_reviewed(query, opts) do
    if Keyword.get(opts, :exclude_unreviewed, false) do
      where(query, [t], not is_nil(t.reviewed_at))
    else
      query
    end
  end

  defp narrow(query, %Query{operators: operators}) do
    Enum.reduce(operators, query, fn
      # `is:` and `has:` arrive as lists, because two of them narrow rather
      # than replace each other.
      {key, values}, acc when is_list(values) ->
        Enum.reduce(values, acc, &operator({key, &1}, &2))

      pair, acc ->
        operator(pair, acc)
    end)
  end

  defp operator({:from, handle}, query) do
    case Accounts.lookup(handle) do
      nil -> where(query, [s], false)
      account -> where(query, [s], s.account_id == ^account.id)
    end
  end

  defp operator({:has, "media"}, query) do
    where(query, [s], fragment("array_length(?, 1) > 0", s.ordered_media_attachment_ids))
  end

  defp operator({:has, "poll"}, query) do
    where(query, [s], fragment("EXISTS (SELECT 1 FROM polls p WHERE p.status_id = ?)", s.id))
  end

  defp operator({:is, "reply"}, query), do: where(query, [s], not is_nil(s.in_reply_to_id))
  defp operator({:is, "sensitive"}, query), do: where(query, [s], s.sensitive)
  defp operator({:is, "boost"}, query), do: where(query, [s], not is_nil(s.reblog_of_id))

  defp operator({:language, language}, query), do: where(query, [s], s.language == ^language)

  # The whole of the named day counts, which is what somebody means by a date
  # rather than a moment.
  defp operator({:before, date}, query), do: where(query, [s], s.inserted_at < ^start_of(date))

  defp operator({:after, date}, query),
    do: where(query, [s], s.inserted_at >= ^start_of(Date.add(date, 1)))

  defp operator({:during, date}, query) do
    where(
      query,
      [s],
      s.inserted_at >= ^start_of(date) and s.inserted_at < ^start_of(Date.add(date, 1))
    )
  end

  defp operator(_operator, query), do: query

  defp start_of(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  ## Accounts

  # Full text for whole words, trigram for the half-typed ones an autocomplete
  # sends. Neither alone answers both.
  defp match_account(term) do
    dynamic(
      [a],
      fragment("? @@ websearch_to_tsquery('simple', ?)", a.searchable, ^term) or
        fragment("similarity(lower(?), ?) > ?", a.username, ^term, ^@similarity) or
        fragment("similarity(lower(coalesce(?, '')), ?) > ?", a.display_name, ^term, ^@similarity)
    )
  end

  # Weighted text first, then somebody the reader already follows, then how
  # many people follow them. The person somebody means is nearly always
  # somebody they already know, which is worth more than any similarity score.
  defp rank_account(term, viewer) do
    followed = followed_ids(viewer)

    dynamic(
      [a, st],
      fragment(
        "(CASE WHEN ? = ANY(?) THEN 1 ELSE 0 END)",
        a.id,
        ^followed
      ) * 10 +
        fragment("ts_rank(?, websearch_to_tsquery('simple', ?))", a.searchable, ^term) * 5 +
        fragment(
          "greatest(similarity(lower(?), ?), similarity(lower(coalesce(?, '')), ?))",
          a.username,
          ^term,
          a.display_name,
          ^term
        ) +
        fragment("ln(1 + coalesce(?, 0)) / 10", st.followers_count)
    )
  end

  defp followed_ids(nil), do: []

  defp followed_ids(%Account{id: id}), do: followed_ids(id)

  defp followed_ids(viewer_id) do
    from(f in Follow, where: f.account_id == ^viewer_id, select: f.target_account_id)
    |> Repo.all()
  end

  # A handle with a domain names one server, and the answer must not include
  # the account with the same name here.
  defp maybe_domain(query, %Query{operators: %{domain: domain}}) do
    where(query, [a], fragment("lower(coalesce(?, ''))", a.domain) == ^String.downcase(domain))
  end

  defp maybe_domain(query, _parsed), do: query

  defp maybe_local(query, opts) do
    if Keyword.get(opts, :local, false), do: where(query, [a], is_nil(a.domain)), else: query
  end
end
