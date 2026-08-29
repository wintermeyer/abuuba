defmodule AbuubaWeb.ClientIP do
  @moduledoc """
  The address a request came from, as far as this server can tell.

  `remote_ip` is what the socket says. Behind a reverse proxy that is the
  proxy, so a deployment behind one has to run a plug that rewrites it from a
  header it actually trusts. Reading `X-Forwarded-For` here unconditionally
  would let any client pick its own rate-limit bucket and defeat the whole
  thing, so that decision belongs to whoever knows the deployment.

  One definition, because the day a trusted-proxy rewrite does land, it has to
  reach every limit at once rather than whichever one somebody remembered.
  """

  @doc """
  The client address, as a string suitable for a bucket key.
  """
  @spec of(Plug.Conn.t()) :: String.t()
  def of(conn), do: address(conn.remote_ip)

  @doc """
  The same, for a LiveView, or `nil` before the socket has connected.

  A LiveView is mounted twice: once to render the page over HTTP and once when
  the socket connects, and only the second mount is given the peer. `nil` on
  the first is therefore ordinary rather than a failure — but a caller using
  this for a block has to treat "I do not know yet" as a reason to wait rather
  than as permission, which is why it is nil and not a placeholder address.
  """
  @spec of_socket(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def of_socket(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} -> address(address)
      _ -> nil
    end
  end

  defp address(nil), do: nil
  defp address(address), do: address |> :inet.ntoa() |> to_string()
end
