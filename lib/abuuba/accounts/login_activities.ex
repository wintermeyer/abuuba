defmodule Abuuba.Accounts.LoginActivities do
  @moduledoc """
  Where an account has been signed in from, and where somebody tried.

  ## The failures are the point

  A list of successful sign-ins tells somebody where they have been, which they
  mostly know. A list that also holds the failed ones tells them that somebody
  else has been trying, and that is the thing worth learning early and the
  thing nothing else on this server would ever surface to them.

  ## It is not an archive

  A record of somebody's whereabouts and their addresses, kept to answer "was
  that me last Tuesday" and swept after a few weeks. Keeping it longer would
  make this table the most interesting thing in a database leak, in exchange
  for answering a question nobody asks about last spring.
  """

  import Ecto.Query

  alias Abuuba.Accounts.LoginActivity
  alias Abuuba.Accounts.User
  alias Abuuba.Repo

  @keep_days 30

  @doc """
  Writes one attempt.

  Never raises and never returns anything a caller has to handle: this is a
  note in the margin of signing in, and a failure to write it must not be the
  reason somebody cannot get in.
  """
  @spec record(User.t() | integer() | nil, keyword()) :: :ok
  def record(nil, _opts), do: :ok
  def record(%User{id: id}, opts), do: record(id, opts)

  def record(user_id, opts) do
    attrs = %{
      user_id: user_id,
      success: Keyword.get(opts, :success, false),
      ip: Keyword.get(opts, :ip),
      user_agent: Keyword.get(opts, :user_agent),
      method: Keyword.get(opts, :method, "password"),
      failure_reason: Keyword.get(opts, :reason)
    }

    %LoginActivity{} |> LoginActivity.changeset(attrs) |> Repo.insert()

    :ok
  rescue
    _error -> :ok
  end

  @doc """
  The recent attempts on one account, newest first.
  """
  @spec recent(User.t() | integer(), pos_integer()) :: [LoginActivity.t()]
  def recent(user, limit \\ 20)
  def recent(%User{id: id}, limit), do: recent(id, limit)

  def recent(user_id, limit) do
    LoginActivity
    |> where([a], a.user_id == ^user_id)
    |> order_by([a], desc: a.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  How long these are kept, in days.
  """
  @spec keep_days() :: pos_integer()
  def keep_days, do: @keep_days

  @doc """
  Deletes the ones past their day.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    cutoff = DateTime.add(DateTime.utc_now(), -@keep_days * 86_400, :second)

    {deleted, _} =
      LoginActivity |> where([a], a.inserted_at < ^cutoff) |> Repo.delete_all()

    deleted
  end
end
