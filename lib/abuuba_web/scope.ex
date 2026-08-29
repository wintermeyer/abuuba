defmodule AbuubaWeb.Scope do
  @moduledoc """
  Reading who is asking, from a conn or a socket.

  One definition instead of the private copy every controller used to carry:
  the copies had already started to disagree about what to do when the scope
  holds a user whose account is not loaded, and a divergence here is a page
  quietly treating a signed-in person as a stranger.

  The session query preloads the account, so the fallback lookup is for the
  odd path that builds a scope some other way.
  """

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account

  @doc """
  The user in the current scope, or `nil`.
  """
  @spec current_user(Plug.Conn.t() | Phoenix.LiveView.Socket.t()) :: struct() | nil
  def current_user(%{assigns: %{current_scope: %{user: %{} = user}}}), do: user
  def current_user(_conn_or_socket), do: nil

  @doc """
  The account of the user in the current scope, or `nil`.
  """
  @spec current_account(Plug.Conn.t() | Phoenix.LiveView.Socket.t()) :: Account.t() | nil
  def current_account(conn_or_socket) do
    case current_user(conn_or_socket) do
      %{account: %Account{} = account} -> account
      %{account_id: id} when not is_nil(id) -> Accounts.get_account(id)
      _ -> nil
    end
  end
end
