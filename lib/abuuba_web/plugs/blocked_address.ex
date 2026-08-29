defmodule AbuubaWeb.Plugs.BlockedAddress do
  @moduledoc """
  Refuses a request from an address an admin has shut out entirely.

  Only the hardest severity reaches here. A sign-up block is about registering
  and says nothing about reading, and treating one as the other would quietly
  wall off everybody behind a shared address because one person misbehaved.

  403 with a plain sentence rather than a blank connection: somebody behind a
  university NAT who cannot read the server should be able to find out that it
  is deliberate and go and ask.
  """

  import Plug.Conn

  alias Abuuba.Moderation.Signup
  alias AbuubaWeb.ClientIP

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if Signup.blocked_from_access?(ClientIP.of(conn)) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "This server does not accept requests from your address.")
      |> halt()
    else
      conn
    end
  end
end
