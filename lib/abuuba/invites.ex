defmodule Abuuba.Invites do
  @moduledoc """
  Codes that let somebody in, and the accounting behind them.

  ## The alphabet leaves out anything that looks like something else

  No `0`, `O`, `1`, `I` or `l`. An invite is typed by hand off a phone screen or
  read out over a table more often than it is clicked, and a code somebody
  cannot transcribe is a code that generates a support conversation instead of
  an account.

  ## Claiming is a conditional update, not a read and a write

  Two people can hand the last use of an invite to the sign-up form at the same
  moment. The claim increments the row only where a use is still left, so the
  loser of that race gets a refusal rather than a second account on a
  single-use invite.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Invites.Invite
  alias Abuuba.Repo
  alias Abuuba.Roles

  # No 0/O, 1/I/l. What is left still gives 32^10 codes, which is more than any
  # server will ever issue.
  @alphabet ~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  @code_length 10

  @doc """
  Writes an invite, if this account may.
  """
  @spec create(Account.t(), map()) ::
          {:ok, Invite.t()} | {:error, :not_allowed | Ecto.Changeset.t()}
  def create(%Account{} = account, attrs) do
    if allowed?(account) do
      %Invite{}
      |> Invite.changeset(Map.merge(attrs, %{"account_id" => account.id, "code" => code()}))
      |> Repo.insert()
    else
      {:error, :not_allowed}
    end
  end

  @doc """
  Everything one account has issued, newest first.
  """
  @spec list(Account.t() | integer(), map()) :: [Invite.t()]
  def list(account, page \\ %{})
  def list(%Account{id: id}, page), do: list(id, page)

  def list(account_id, page) do
    Invite
    |> where([i], i.account_id == ^account_id)
    |> order_by([i], desc: i.id)
    |> limit(^Map.get(page, :limit, 100))
    |> Repo.all()
  end

  @doc """
  One of an account's own invites by id, or `nil`.
  """
  @spec get(Account.t(), integer() | String.t()) :: Invite.t() | nil
  def get(%Account{id: account_id}, id) do
    case Integer.parse(to_string(id)) do
      {number, ""} -> Repo.get_by(Invite, id: number, account_id: account_id)
      _ -> nil
    end
  end

  @doc """
  One invite by code, whether or not it is still usable.
  """
  @spec get_by_code(String.t() | nil) :: Invite.t() | nil
  def get_by_code(nil), do: nil
  def get_by_code(""), do: nil
  def get_by_code(code), do: Repo.get_by(Invite, code: String.upcase(String.trim(code)))

  @doc """
  Spends one use of an invite.

  The increment is conditional on a use still being left, so two sign-ups
  racing for the last one cannot both win.
  """
  @spec claim(String.t() | nil) :: {:ok, Invite.t()} | {:error, atom()}
  def claim(code) do
    now = DateTime.utc_now()

    case get_by_code(code) do
      nil ->
        {:error, :not_found}

      invite ->
        cond do
          Invite.expired?(invite, now) -> {:error, :expired}
          Invite.used_up?(invite) -> {:error, :used_up}
          true -> spend(invite, now)
        end
    end
  end

  @doc """
  Takes an invite back. Only whoever wrote it may.
  """
  @spec delete(Account.t(), Invite.t()) :: :ok | {:error, :not_yours}
  def delete(%Account{id: id}, %Invite{account_id: id} = invite) do
    Repo.delete(invite)

    :ok
  end

  def delete(_account, _invite), do: {:error, :not_yours}

  @doc """
  Whether an account may write invites at all.
  """
  @spec allowed?(Account.t()) :: boolean()
  def allowed?(%Account{id: id}) do
    case Repo.get_by(Abuuba.Accounts.User, account_id: id) do
      nil -> false
      user -> Roles.can?(user, "invite_users")
    end
  end

  @doc """
  A fresh code.
  """
  @spec code() :: String.t()
  def code do
    1..@code_length
    |> Enum.map(fn _ -> Enum.random(@alphabet) end)
    |> List.to_string()
  end

  defp spend(invite, now) do
    {count, _} =
      Invite
      |> where([i], i.id == ^invite.id)
      |> where([i], is_nil(i.max_uses) or i.uses < i.max_uses)
      |> Repo.update_all(inc: [uses: 1], set: [updated_at: now])

    if count == 1 do
      {:ok, Repo.get(Invite, invite.id)}
    else
      {:error, :used_up}
    end
  end
end
