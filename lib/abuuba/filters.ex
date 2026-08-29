defmodule Abuuba.Filters do
  @moduledoc """
  What somebody has asked not to read, and what matched.

  ## Nothing is filtered on the way out

  A filtered post is still delivered; the response says which filters matched
  it and what the reader asked be done. That is deliberate. A filter is a
  reading preference rather than moderation: the person can lift one and see
  what they missed, a client can offer "show anyway" without another request,
  and a server that quietly dropped posts would leave somebody with gaps in a
  conversation and no way to tell why.

  ## Matching

  Case-insensitively, over the post's text and its content warning. A content
  warning is exactly where somebody names the topic being filtered, so
  ignoring it would let the one post that announced the subject through.
  """

  import Ecto.Query

  # A century, which is longer than any filter anybody means and short enough
  # that the resulting instant is a timestamp Postgres can hold.
  @max_expires_in 100 * 365 * 24 * 60 * 60

  alias Abuuba.Accounts.Account
  alias Abuuba.Filters.Filter
  alias Abuuba.Filters.FilterStatus
  alias Abuuba.Filters.Keyword, as: FilterKeyword
  alias Abuuba.Repo
  alias Abuuba.Statuses.Status
  alias Abuuba.Streaming
  alias AbuubaWeb.API.NestedParams

  @doc """
  Somebody's filters, newest first, with their keywords.
  """
  @spec all(Account.t() | integer()) :: [Filter.t()]
  def all(%Account{id: id}), do: all(id)

  def all(account_id) do
    Filter
    |> where([f], f.account_id == ^account_id)
    |> order_by([f], desc: f.id)
    |> preload([:keywords, :statuses])
    |> Repo.all()
  end

  @doc """
  Every spelling in somebody's filters, each carrying the rule it belongs to.

  What the older API calls a filter. That API has no way to say "one rule, two
  spellings", so a rule with two keywords is two filters to it, and the id it
  hands out names the keyword rather than the rule.
  """
  @spec keywords_for(Account.t() | integer()) :: [FilterKeyword.t()]
  def keywords_for(%Account{id: id}), do: keywords_for(id)

  def keywords_for(account_id) do
    FilterKeyword
    |> join(:inner, [k], f in Filter, on: f.id == k.filter_id)
    |> where([_k, f], f.account_id == ^account_id)
    |> order_by([k], desc: k.id)
    |> preload([_k, f], filter: f)
    |> Repo.all()
  end

  @doc """
  How many spellings a filter has.
  """
  @spec keyword_count(Filter.t() | integer()) :: non_neg_integer()
  def keyword_count(%Filter{id: id}), do: keyword_count(id)

  def keyword_count(filter_id) do
    FilterKeyword |> where([k], k.filter_id == ^filter_id) |> Repo.aggregate(:count)
  end

  @doc """
  Changes one spelling.
  """
  @spec update_keyword(FilterKeyword.t(), map()) ::
          {:ok, FilterKeyword.t()} | {:error, Ecto.Changeset.t()}
  def update_keyword(%FilterKeyword{} = keyword, attrs) do
    keyword
    |> FilterKeyword.changeset(normalise(attrs))
    |> Repo.update(stale_error_field: :id)
    |> announce_for_filter(keyword.filter_id)
  end

  @doc """
  One of somebody's filters, scoped to the owner.
  """
  @spec get(Account.t() | integer(), integer() | nil) :: Filter.t() | nil
  def get(%Account{id: id}, filter_id), do: get(id, filter_id)
  def get(_account_id, nil), do: nil

  def get(account_id, filter_id) do
    Filter
    |> where([f], f.id == ^filter_id and f.account_id == ^account_id)
    |> preload([:keywords, :statuses])
    |> Repo.one()
  end

  @doc """
  Creates a filter, with its keywords in the same call.

  A rule and its spellings arrive together because that is how somebody writes
  one: "hide anything about the election" is not a rule until it says which
  words that means.
  """
  @spec create(Account.t(), map()) :: {:ok, Filter.t()} | {:error, Ecto.Changeset.t()}
  def create(%Account{id: account_id}, attrs) do
    attrs = normalise(attrs)

    # One transaction, because a rule and its spellings are one thing to
    # whoever wrote them. Without it a keyword too long to store leaves a rule
    # behind that looks saved and looks for nothing.
    Repo.transaction(fn ->
      with {:ok, filter} <-
             %Filter{}
             |> Filter.changeset(Map.put(attrs, "account_id", account_id))
             |> Repo.insert(),
           :ok <- put_keywords(filter, Map.get(attrs, "keywords_attributes", [])) do
        get(account_id, filter.id)
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> announce()
  end

  @doc """
  Changes a filter, replacing its keywords where any were given.
  """
  @spec update(Filter.t(), map()) :: {:ok, Filter.t()} | {:error, Ecto.Changeset.t()}
  def update(%Filter{} = filter, attrs) do
    attrs = normalise(attrs)

    Repo.transaction(fn ->
      with {:ok, updated} <-
             filter |> Filter.changeset(attrs) |> Repo.update(stale_error_field: :id),
           :ok <- replace_keywords(updated, Map.get(attrs, "keywords_attributes")) do
        get(updated.account_id, updated.id)
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> announce()
  end

  @doc """
  The instant an `expires_in`, in seconds, names.

  `nil` for attributes that carry no expiry, and for an explicitly empty one,
  which is how a client takes an expiry back off. Public because deciding
  whether a request changes a rule's expiry means comparing the instant it
  asks for against the one already stored, and doing that in a caller would be
  a second opinion about what `expires_in` means.
  """
  @spec expires_at(map()) :: DateTime.t() | nil
  def expires_at(attrs) do
    case attrs |> normalise_keys() |> Map.get("expires_in") do
      value when value in [nil, ""] -> nil
      value -> resolve(value)
    end
  end

  # An expiry a hundred years out is somebody's client sending a sentinel, and
  # one past the year Postgres can store is a 500 rather than an answer. Capped
  # rather than refused: every real value is far below this and lands exactly,
  # and the reference implementation has no opinion to be compatible with here.
  defp resolve(value) do
    case seconds(value) do
      nil -> nil
      seconds -> DateTime.add(DateTime.utc_now(), min(seconds, @max_expires_in), :second)
    end
  end

  @doc """
  Deletes one.
  """
  @spec delete(Filter.t()) :: {:ok, Filter.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Filter{} = filter),
    do: filter |> Repo.delete(stale_error_field: :id) |> announce()

  @doc """
  Adds one spelling to an existing filter.
  """
  @spec add_keyword(Filter.t(), map()) ::
          {:ok, FilterKeyword.t()} | {:error, Ecto.Changeset.t()}
  def add_keyword(%Filter{id: filter_id}, attrs) do
    %FilterKeyword{}
    |> FilterKeyword.changeset(Map.put(normalise(attrs), "filter_id", filter_id))
    |> Repo.insert()
    |> announce_for_filter(filter_id)
  end

  @doc """
  One keyword, scoped to whoever owns the filter it belongs to.
  """
  @spec get_keyword(Account.t() | integer(), integer() | nil) :: FilterKeyword.t() | nil
  def get_keyword(%Account{id: id}, keyword_id), do: get_keyword(id, keyword_id)
  def get_keyword(_account_id, nil), do: nil

  def get_keyword(account_id, keyword_id) do
    FilterKeyword
    |> join(:inner, [k], f in Filter, on: f.id == k.filter_id)
    |> where([k, f], k.id == ^keyword_id and f.account_id == ^account_id)
    |> preload([_k, f], filter: f)
    |> Repo.one()
  end

  @doc """
  The posts a filter catches by name.
  """
  @spec statuses(Filter.t() | integer()) :: [FilterStatus.t()]
  def statuses(%Filter{id: id}), do: statuses(id)

  def statuses(filter_id) do
    FilterStatus
    |> where([fs], fs.filter_id == ^filter_id)
    |> order_by([fs], desc: fs.id)
    |> Repo.all()
  end

  @doc """
  Catches one post by name.

  For the post that gets past the words: a keyword cannot say "that one", and
  this is how somebody does.
  """
  @spec add_status(Filter.t(), map()) ::
          {:ok, FilterStatus.t()} | {:error, Ecto.Changeset.t()}
  def add_status(%Filter{id: filter_id}, attrs) do
    %FilterStatus{}
    |> FilterStatus.changeset(Map.put(normalise_keys(attrs), "filter_id", filter_id))
    |> Repo.insert()
    |> announce_for_filter(filter_id)
  end

  @doc """
  One of them, scoped to whoever owns the filter it belongs to.
  """
  @spec get_status(Account.t() | integer(), integer() | nil) :: FilterStatus.t() | nil
  def get_status(%Account{id: id}, filter_status_id), do: get_status(id, filter_status_id)
  def get_status(_account_id, nil), do: nil

  def get_status(account_id, filter_status_id) do
    FilterStatus
    |> join(:inner, [fs], f in Filter, on: f.id == fs.filter_id)
    |> where([fs, f], fs.id == ^filter_status_id and f.account_id == ^account_id)
    |> Repo.one()
  end

  @doc """
  Stops catching it.
  """
  @spec delete_status(FilterStatus.t()) ::
          {:ok, FilterStatus.t()} | {:error, Ecto.Changeset.t()}
  def delete_status(%FilterStatus{} = filter_status) do
    filter_status
    |> Repo.delete(stale_error_field: :id)
    |> announce_for_filter(filter_status.filter_id)
  end

  @doc """
  Removes one spelling.
  """
  @spec delete_keyword(FilterKeyword.t()) ::
          {:ok, FilterKeyword.t()} | {:error, Ecto.Changeset.t()}
  def delete_keyword(%FilterKeyword{} = keyword) do
    keyword
    |> Repo.delete(stale_error_field: :id)
    |> announce_for_filter(keyword.filter_id)
  end

  @doc """
  Which of somebody's filters match a post, in one context.

  Returns the filters that matched rather than a decision, because the decision
  belongs to the reader's client: one person's `warn` is a fold-away and
  another's `hide` is a removal, and both want to know it was their own rule
  that did it.
  """
  @spec matching(Account.t() | integer() | nil, Status.t(), String.t()) :: [Filter.t()]
  def matching(nil, _status, _context), do: []
  def matching(%Account{id: id}, status, context), do: matching(id, status, context)

  def matching(account_id, %Status{} = status, context) do
    account_id |> all() |> match(status, context)
  end

  @doc """
  The same, against filters already in hand.

  Rendering a page asks this once per post, and the reader's rules do not
  change between the first and the twentieth. Loading them once and matching in
  memory is the difference between one query for a page and one per post.
  """
  @spec match([Filter.t()], Status.t(), String.t()) :: [Filter.t()]
  def match([], %Status{}, _context), do: []

  def match(filters, %Status{} = status, context) when is_list(filters) do
    now = DateTime.utc_now()
    haystack = haystack(status)
    # A boost is filtered by whatever filters the post it carries: somebody who
    # asked not to see a post did not ask to see it through somebody else.
    subject_ids = Enum.reject([status.id, status.reblog_of_id], &is_nil/1)

    Enum.filter(filters, fn filter ->
      context in filter.context and not Filter.expired?(filter, now) and
        (names?(filter, subject_ids) or Enum.any?(filter.keywords, &matches?(&1, haystack)))
    end)
  end

  # Read off the rows already loaded with the filter rather than asked for per
  # post: this runs once for every status on a page, and a query in here is a
  # query per post in a timeline.
  defp names?(%Filter{statuses: statuses}, subject_ids) when is_list(statuses) do
    Enum.any?(statuses, &(&1.status_id in subject_ids))
  end

  defp names?(_filter, _subject_ids), do: false

  @doc """
  Whether one keyword is in a piece of text.
  """
  @spec matches?(FilterKeyword.t(), String.t()) :: boolean()
  def matches?(%FilterKeyword{keyword: keyword, whole_word: whole_word}, text) do
    needle = String.downcase(String.trim(keyword))
    haystack = String.downcase(text)

    cond do
      needle == "" ->
        false

      whole_word ->
        Regex.match?(~r/(?<![\p{L}\p{N}_])#{Regex.escape(needle)}(?![\p{L}\p{N}_])/u, haystack)

      true ->
        String.contains?(haystack, needle)
    end
  end

  # The content warning as well as the text. A warning is exactly where
  # somebody names the topic being filtered, so a match that ignored it would
  # let the one post that announced the subject through.
  defp haystack(%Status{} = status) do
    [status.text, status.spoiler_text] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  # The first bad spelling stops the lot. Reported rather than skipped: a
  # client that asked for three keywords and silently got two would have a rule
  # that reads as saved and misses what it was written for.
  defp put_keywords(filter, keywords) do
    keywords
    |> NestedParams.list()
    |> Enum.reduce_while(:ok, fn
      attrs, :ok when is_map(attrs) ->
        case add_keyword(filter, attrs) do
          {:ok, _keyword} -> {:cont, :ok}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end

      # Something that is not a keyword object at all. Refused for the same
      # reason a keyword too long to store is: saving the rest would leave a
      # filter that reads as saved and looks for less than it was asked to.
      # The id is filled in so the answer names the one thing the client got
      # wrong, rather than adding a `filter_id` error it can do nothing about.
      _malformed, :ok ->
        blank = FilterKeyword.changeset(%FilterKeyword{}, %{"filter_id" => filter.id})
        {:halt, {:error, blank}}
    end)
  end

  # Saying nothing about the keywords leaves them alone, which is what a
  # request that only renames a rule means.
  defp replace_keywords(_filter, nil), do: :ok

  defp replace_keywords(filter, keywords) do
    FilterKeyword |> where([k], k.filter_id == ^filter.id) |> Repo.delete_all()

    put_keywords(filter, keywords)
  end

  # After the transaction rather than inside it: telling a client its filters
  # changed and then rolling the write back would leave it re-reading a set
  # that never changed, which is harmless, and doing it the other way round
  # would leave it hiding by rules that no longer exist, which is not.
  defp announce({:ok, %Filter{account_id: account_id}} = result) do
    Streaming.publish_filters_changed(account_id)

    result
  end

  defp announce(result), do: result

  # A keyword or a status names its filter rather than its owner, and the
  # owner is who the stream belongs to.
  defp announce_for_filter({:ok, _record} = result, filter_id) do
    case Repo.one(from(f in Filter, where: f.id == ^filter_id, select: f.account_id)) do
      nil -> result
      account_id -> Streaming.publish_filters_changed(account_id) && result
    end
  end

  defp announce_for_filter(result, _filter_id), do: result

  defp normalise(attrs),
    do: attrs |> normalise_keys() |> resolve_context() |> resolve_expires_in()

  # `context[0]=home` is a map keyed by the index by the time it gets here, and
  # `{:array, :string}` has no idea what to do with one -- the answer was "must
  # name at least one context" for a request that named one.
  defp resolve_context(%{"context" => context} = attrs) when not is_nil(context),
    do: Map.put(attrs, "context", NestedParams.list(context))

  defp resolve_context(attrs), do: attrs

  defp normalise_keys(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  # Clients say `expires_in` in seconds; the column holds the instant. Resolved
  # here rather than in the changeset because it is a question about now, and a
  # changeset that reads the clock is a changeset nobody can test twice.
  #
  # An explicitly empty one clears the expiry, which is how a client takes one
  # back off. Absent is not empty: a request that says nothing about expiry
  # must leave it alone.
  defp resolve_expires_in(%{"expires_in" => _value} = attrs) do
    Map.put(attrs, "expires_at", expires_at(attrs))
  end

  defp resolve_expires_in(attrs), do: attrs

  defp seconds(value) when is_integer(value), do: value

  defp seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, _rest} -> seconds
      :error -> nil
    end
  end

  defp seconds(_value), do: nil
end
