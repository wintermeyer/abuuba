defmodule AbuubaWeb.Plugs.RequireUser do
  @moduledoc """
  Refuses a request that needs a person behind it.

  The status codes are the reference implementation's, and two of them look
  wrong:

  * **422** when there is no token at all, where 401 is the obvious answer;
  * **403** for an account that exists but cannot act yet, whether that is an
    unconfirmed address, an approval still pending, or a disabled login.

  Both are deliberate here. Clients branch on these codes: a 401 makes an app
  discard the token it holds and send the person back through the whole OAuth
  flow, so answering 401 where the reference answers 422 logs people out of an
  app that was working a moment earlier. The 403s are distinguished by their
  message rather than their status, and apps show that message.

  The messages are English literals rather than translated strings, and that is
  the same decision: clients match on them, and a message that changed language
  with the request would break an app that had been reading it. Apps translate
  what they show; this is a protocol string.

  Do not tidy this up. See `AbuubaWeb.API`.
  """

  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.User
  alias AbuubaWeb.API

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case conn.assigns[:current_scope] do
      %{user: %User{} = user} -> check(conn, user)
      _ -> API.error(conn, 422, "This method requires an authenticated user")
    end
  end

  defp check(conn, %User{confirmed_at: nil}) do
    API.error(conn, 403, "Your login is missing a confirmed e-mail address")
  end

  defp check(conn, %User{approved: false}) do
    API.error(conn, 403, "Your login is currently pending approval")
  end

  defp check(conn, %User{account: %Account{suspended_at: nil}}), do: conn

  # Suspended, or an account we cannot see. "We could not check" has to mean
  # "no": the alternative is a suspended account acting through whichever code
  # path forgot to load it.
  defp check(conn, _user), do: API.error(conn, 403, "Your login is currently disabled")
end
