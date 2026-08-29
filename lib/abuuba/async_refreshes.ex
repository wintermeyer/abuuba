defmodule Abuuba.AsyncRefreshes do
  @moduledoc """
  Work a client is waiting on, and how far along it is.

  Some answers are only half here at the moment they are asked for. A thread
  whose upper half lives on another server, a search whose remote half is in
  flight: the request could block on the network, and then a slow third party
  decides how long this server takes to answer. Instead the endpoint answers
  with what it has, starts the rest, and names it in a `Mastodon-Async-Refresh`
  header. The client polls `GET /api/v1_alpha/async_refreshes/:id` and asks
  again when the count has moved.

  ## Why a row and not a cache entry

  Mastodon keeps these in Redis under a signed key. abuuba has one datastore, so
  they are rows that carry their own expiry. That also makes the id an ordinary
  record id rather than a signed blob, which is why every read is scoped to the
  account that started it: an id somebody else can guess must not be an id
  somebody else can read.

  ## Starting one twice starts one

  Two tabs open on the same thread ask for the same refresh, and the second ask
  joins the first rather than doubling the work. That is the partial unique
  index on `(account_id, key)` where the row is still running, so the race
  between two requests resolves in the database rather than in whoever checked
  first.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.AsyncRefreshes.AsyncRefresh
  alias Abuuba.Repo
  alias Abuuba.Snowflake

  # A refresh nobody finished is a refresh whose worker died. Kept a day so a
  # client that polls slowly still gets an answer, rather than a 404 that reads
  # as "the thread you were looking at does not exist".
  @running_ttl_seconds 86_400

  # Once finished there is nothing left to report but the final count, and the
  # client stops polling as soon as it reads `finished`. An hour is enough for
  # the poll already in flight.
  @finished_ttl_seconds 3_600

  @doc """
  Starts one, or returns the one already running for the same work.

  Pass `count_results: true` where the work has something countable to report;
  without it the refresh reports only whether it is done.

  Answers `{:started, refresh}` only for the caller that actually created it,
  and `{:joined, refresh}` for one that found the work already going. That is
  the difference between queueing the job and not: two tabs asking at once
  should watch the same rebuild rather than run two.

  `:error` where none could be had at all. Tracking progress is a courtesy on
  top of an answer the endpoint has already assembled, so failing to track it
  must not fail the request.
  """
  @spec start(Account.t() | integer(), String.t(), keyword()) ::
          {:started, AsyncRefresh.t()} | {:joined, AsyncRefresh.t()} | :error
  def start(account, key, opts \\ [])
  def start(%Account{id: id}, key, opts), do: start(id, key, opts)

  def start(account_id, key, opts) do
    attrs = %{
      account_id: account_id,
      key: key,
      status: "running",
      result_count: if(Keyword.get(opts, :count_results, false), do: 0),
      expires_at: expiry(@running_ttl_seconds)
    }

    case Repo.insert(AsyncRefresh.changeset(%AsyncRefresh{}, attrs)) do
      {:ok, refresh} ->
        {:started, refresh}

      {:error, _changeset} ->
        join_or_take_over(account_id, key, attrs)
    end
  end

  # Lost the race with another request, or the work was already going.
  #
  # The index holds every running row, expired or not, while `running/2` only
  # answers with live ones — so a row whose worker died and whose day has
  # passed would otherwise block the key until the sweep gets to it, and the
  # caller would be told `:error` on a feed nothing was rebuilding. Such a row
  # is retired here and the insert tried once more.
  defp join_or_take_over(account_id, key, attrs) do
    case running(account_id, key) do
      %AsyncRefresh{} = refresh ->
        {:joined, refresh}

      nil ->
        AsyncRefresh
        |> where([r], r.account_id == ^account_id and r.key == ^key and r.status == "running")
        |> Repo.update_all(set: [status: "finished", updated_at: DateTime.utc_now()])

        case Repo.insert(AsyncRefresh.changeset(%AsyncRefresh{}, attrs)) do
          {:ok, refresh} -> {:started, refresh}
          {:error, _changeset} -> :error
        end
    end
  end

  @doc """
  The refresh with this id, if it belongs to this account and has not expired.
  """
  @spec get(Account.t() | integer(), term()) :: AsyncRefresh.t() | nil
  def get(%Account{id: id}, refresh_id), do: get(id, refresh_id)

  def get(account_id, refresh_id) do
    case numeric(refresh_id) do
      {:ok, id} ->
        AsyncRefresh
        |> where([r], r.id == ^id and r.account_id == ^account_id)
        |> where([r], r.expires_at > ^DateTime.utc_now())
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc """
  The one still running for this work, if any.
  """
  @spec running(Account.t() | integer(), String.t()) :: AsyncRefresh.t() | nil
  def running(%Account{id: id}, key), do: running(id, key)

  def running(account_id, key) do
    AsyncRefresh
    |> where([r], r.account_id == ^account_id and r.key == ^key and r.status == "running")
    |> where([r], r.expires_at > ^DateTime.utc_now())
    |> Repo.one()
  end

  @doc """
  Marks the work done, optionally recording what it turned up.

  Idempotent, because a worker that runs twice is the ordinary case with a job
  queue and not a reason to raise.
  """
  @spec finish(AsyncRefresh.t() | term() | nil, keyword()) :: :ok
  def finish(refresh, opts \\ [])
  def finish(nil, _opts), do: :ok

  def finish(%AsyncRefresh{} = refresh, opts) do
    set = [
      status: "finished",
      expires_at: expiry(@finished_ttl_seconds),
      updated_at: DateTime.utc_now()
    ]

    set =
      case Keyword.fetch(opts, :result_count) do
        {:ok, count} when is_integer(count) -> Keyword.put(set, :result_count, count)
        _ -> set
      end

    AsyncRefresh
    |> where([r], r.id == ^refresh.id)
    |> Repo.update_all(set: set)

    :ok
  end

  # A worker holds an id rather than a row, and the row may already have been
  # swept. Finishing something that is gone is finished, so this neither reads
  # first nor cares how many rows it touched.
  def finish(refresh_id, opts) do
    case numeric(refresh_id) do
      {:ok, id} -> finish(%AsyncRefresh{id: id}, opts)
      :error -> :ok
    end
  end

  @doc """
  Deletes the rows nobody can read any more.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    {deleted, _} =
      AsyncRefresh
      |> where([r], r.expires_at <= ^DateTime.utc_now())
      |> Repo.delete_all()

    deleted
  end

  defp expiry(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  # Through the id type rather than `Integer.parse/1`, which happily returns a
  # number too large for a bigint column and turns a bad id in a URL into a
  # Postgrex encode error rather than a 404.
  defp numeric(value) do
    case Snowflake.cast(value) do
      {:ok, id} -> {:ok, id}
      _ -> :error
    end
  end
end
