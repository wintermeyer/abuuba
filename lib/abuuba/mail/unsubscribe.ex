defmodule Abuuba.Mail.Unsubscribe do
  @moduledoc """
  The signed statement behind every unsubscribe link.

  ## Signed, not stored

  The token says which account and which kind of mail, signed with this
  server's secret. Nothing is written when a message goes out, so there is no
  table to grow, no row to leak, and nothing to guess: a token this server did
  not sign is not a token.

  It carries no expiry on purpose. Somebody finding a year-old message in their
  archive and wanting the mail to stop is exactly the person this exists for,
  and an expired unsubscribe link is a person who marks the message as spam
  instead — which costs this server's reputation for everybody on it.
  """

  alias Abuuba.Accounts.User
  alias Abuuba.Repo

  @salt "unsubscribe"

  # What a message can be turned off. `all` is the one somebody reaches for
  # when they are cross, and it has to be there or the rest is a maze.
  @kinds ~w(notifications digest all)

  @doc """
  The kinds of mail a link may turn off.
  """
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  A token for one person and one kind of mail.
  """
  @spec token(User.t() | integer(), String.t()) :: String.t()
  def token(%User{id: id}, kind), do: token(id, kind)

  def token(user_id, kind) when kind in @kinds do
    Phoenix.Token.sign(AbuubaWeb.Endpoint, @salt, {user_id, kind})
  end

  @doc """
  Reads one back, or `:error`.
  """
  @spec verify(String.t()) :: {:ok, integer(), String.t()} | :error
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(AbuubaWeb.Endpoint, @salt, token, max_age: :infinity) do
      {:ok, {user_id, kind}} when kind in @kinds -> {:ok, user_id, kind}
      _ -> :error
    end
  end

  def verify(_token), do: :error

  @doc """
  Records that this person does not want that kind of mail.
  """
  @spec apply(User.t(), String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def apply(%User{} = user, kind) when kind in @kinds do
    settings = Map.put(user.settings || %{}, "email_" <> kind, false)

    user |> Ecto.Changeset.change(settings: settings) |> Repo.update()
  end

  @doc """
  Whether this person still wants that kind of mail.

  Anything about their own account — a password reset, a confirmation — is not
  asked about here and never stops: turning off "every email" cannot be
  allowed to lock somebody out of their own account.
  """
  @spec wants?(User.t(), String.t()) :: boolean()
  def wants?(%User{settings: settings}, kind) when is_map(settings) do
    Map.get(settings, "email_all", true) != false and
      Map.get(settings, "email_" <> kind, true) != false
  end

  def wants?(_user, _kind), do: true
end
