defmodule Abuuba.Accounts.Migration do
  @moduledoc """
  Leaving this server for another one, and taking the followers along.

  A `Move` asks every server that follows an account to follow a different one
  instead. That is a large thing to ask, so the same three conditions this
  server insists on when somebody moves *to* it apply on the way out.

  **The new account has to claim this one back.** Its `alsoKnownAs` must name
  this account, and the check is made by fetching that account's own document
  rather than by believing what was typed. Without it anybody could name any
  account as their destination and hand a follower list to a stranger.

  **A cooldown.** Thirty days between moves. Moving repeatedly is how a
  follower list gets walked across the network faster than anybody can notice,
  and the person actually moving house does it once.

  **It is announced, not enforced.** Every server that follows gets the `Move`
  and decides for itself; this server changes its own local followers over and
  tells the rest. Doing anything else on another server's behalf is the thing
  the receiving side exists to prevent.

  ## What arrives at the other end

  A wave of follow requests, because every follower's server acts on the Move
  at once. An account that approves followers by hand cannot be asked to click
  a thousand times, so `Abuuba.Relationships.accept_all_follow_requests/1` is
  there for exactly that morning.
  """

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Delivery
  alias Abuuba.Federation.ResolveActor
  alias Abuuba.Federation.Serializer
  alias Abuuba.Relationships
  alias Abuuba.Repo

  # Thirty days. Longer than the seven the receiving side allows, because that
  # one is guarding against a chain of moves between servers and this one is
  # about somebody's own account: moving house twice in a month is not
  # something to make easy.
  @cooldown_days 30

  @doc """
  How long somebody must wait between moves.
  """
  @spec cooldown_days() :: pos_integer()
  def cooldown_days, do: @cooldown_days

  @doc """
  Moves an account to another one, and tells everybody who follows it.

  `{:ok, account}`, or the reason it cannot happen — each of which is something
  the person can act on rather than a bare refusal.
  """
  @spec move(Account.t(), String.t(), keyword()) ::
          {:ok, Account.t()}
          | {:error, :moved_too_recently | :unknown_account | :no_backlink | :same_account}
  def move(%Account{} = account, target_handle, opts \\ []) do
    with :ok <- check_cooldown(account),
         {:ok, target} <- resolve(target_handle, opts),
         :ok <- check_not_self(account, target),
         :ok <- check_backlink(account, target) do
      record_and_announce(account, target, opts)
    end
  end

  @doc """
  Whether this account may move right now, and when it may if not.
  """
  @spec movable?(Account.t()) :: boolean()
  def movable?(%Account{} = account), do: check_cooldown(account) == :ok

  @doc """
  Undoes a move, for somebody who came back.

  The pointer is what other servers read, so clearing it is what stops them
  forwarding. The cooldown stays where it is: coming back does not buy another
  move.
  """
  @spec cancel(Account.t()) :: {:ok, Account.t()} | {:error, term()}
  def cancel(%Account{} = account) do
    Accounts.update_account(account, %{moved_to_account_id: nil})
  end

  ## The conditions

  defp check_cooldown(%Account{moved_at: nil}), do: :ok

  defp check_cooldown(%Account{moved_at: at}) do
    if DateTime.diff(DateTime.utc_now(), at, :day) >= @cooldown_days do
      :ok
    else
      {:error, :moved_too_recently}
    end
  end

  defp check_not_self(%Account{id: id}, %Account{id: id}), do: {:error, :same_account}
  defp check_not_self(_account, _target), do: :ok

  # The consent half, from this side. The destination's own document has to
  # name this account, which is something only whoever holds that account can
  # arrange.
  defp check_backlink(account, target) do
    if Actor.id(account) in (target.also_known_as || []) do
      :ok
    else
      {:error, :no_backlink}
    end
  end

  defp resolve(handle, opts) do
    handle = handle |> to_string() |> String.trim() |> String.trim_leading("@")

    case ResolveActor.resolve_handle(handle, opts) do
      {:ok, account} -> {:ok, account}
      _unreachable -> {:error, :unknown_account}
    end
  end

  ## Doing it

  defp record_and_announce(account, target, opts) do
    with {:ok, moved} <-
           Accounts.update_account(account, %{
             moved_to_account_id: target.id,
             moved_at: DateTime.utc_now()
           }) do
      move_local_followers(moved, target)
      announce(moved, target, opts)

      {:ok, moved}
    end
  end

  # The followers on this server are this server's to move, and moving them is
  # the whole point. Follow first, then unfollow: the other order leaves
  # somebody following nobody if the second step fails, and following both for
  # a moment is a much smaller wrong than following neither.
  defp move_local_followers(account, target) do
    account
    |> local_follower_ids()
    |> Enum.each(fn follower_id ->
      Relationships.follow(follower_id, target.id)
      Relationships.unfollow(follower_id, account.id)
    end)
  end

  defp local_follower_ids(%Account{id: id}) do
    Relationships.Follow
    |> join(:inner, [f], a in Account, on: a.id == f.account_id)
    |> where([f, a], f.target_account_id == ^id and is_nil(a.domain))
    |> select([f], f.account_id)
    |> Repo.all()
  end

  # Everybody else's servers get the activity and decide for themselves. That
  # is the whole of what this server may do about followers it does not hold.
  defp announce(account, target, opts) do
    if Keyword.get(opts, :announce, true) do
      Delivery.distribute(account, Serializer.move(account, Actor.id(target)))
    end

    :ok
  end
end
