defmodule AbuubaWeb.UserAuth do
  @moduledoc """
  Signing in and out, and knowing who is signed in.

  The session token lives in the session cookie, which Phoenix signs, and the
  session is renewed on sign-in so that a token captured before someone logged
  in cannot be used afterwards.
  """

  use AbuubaWeb, :verified_routes

  use Gettext, backend: AbuubaWeb.Gettext

  import Phoenix.Controller
  import Plug.Conn

  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.User

  @remember_me_cookie "_abuuba_user_remember_me"
  @remember_me_options [sign: true, max_age: 60 * 60 * 24 * 60, same_site: "Lax"]

  @doc """
  Signs somebody in and sends them on their way.
  """
  def log_in_user(conn, %User{} = user, params \\ %{}) do
    token = Auth.create_session_token(user)

    conn
    |> renew_session()
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
    |> maybe_write_remember_me(token, params)
    |> redirect(to: signed_in_path(conn))
  end

  @doc """
  Signs somebody out, everywhere this session reached.
  """
  def log_out_user(conn) do
    token = get_session(conn, :user_token)
    token && Auth.delete_session_token(token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      AbuubaWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> redirect(to: ~p"/")
  end

  @doc """
  Puts the signed-in user, if any, on the connection.
  """
  def fetch_current_scope(conn, _opts) do
    {token, conn} = ensure_user_token(conn)
    user = token && Auth.get_user_by_session_token(token)

    assign(conn, :current_scope, %{user: usable(user)})
  end

  # The same question the sign-in asks, asked again here. A moderator
  # suspending or disabling somebody changes the answer while they are signed
  # in, and this path only ever checked that a session existed -- so the
  # strongest action a moderator has closed the API, which checks on every
  # request, and left every page of this server's own interface open.
  defp usable(nil), do: nil

  defp usable(%User{} = user) do
    case Auth.check_sign_in(user) do
      :ok -> user
      {:error, _reason} -> nil
    end
  end

  @doc """
  Refuses the request unless somebody is signed in.
  """
  def require_authenticated_user(conn, _opts) do
    case conn.assigns[:current_scope] do
      %{user: %User{}} ->
        conn

      _ ->
        conn
        |> put_flash(:error, gettext("You have to be signed in to see that page."))
        |> maybe_store_return_to()
        |> redirect(to: ~p"/login")
        |> halt()
    end
  end

  @doc """
  Sends an already signed-in visitor away from the sign-in pages.
  """
  def redirect_if_user_is_authenticated(conn, _opts) do
    case conn.assigns[:current_scope] do
      %{user: %User{}} -> conn |> redirect(to: signed_in_path(conn)) |> halt()
      _ -> conn
    end
  end

  @doc """
  Makes the signed-in user available to a LiveView.

  Every page of this server's own interface is a LiveView, so this is the twin
  of `fetch_current_scope/2` and has to ask the same question: a session that
  exists is not the same as a session that may be used. It asked only the
  first, which left a suspended account signed in on every live page.

  A LiveView also asks once and then holds the answer for as long as the socket
  lives, so the mount subscribes to the user's sessions and shuts the page down
  when they are revoked. Without it a moderator's decision took effect whenever
  the person happened to reload, and "sign out everywhere" left the browser it
  was pressed in signed in.
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    # A public page goes on being a public page: it is drawn again as a
    # stranger would get it, rather than answering "you have to be signed in to
    # see that page" about a page anybody can see. Drawn again rather than
    # patched, because the reader is not only in the scope -- every screen
    # takes an account out of it at mount and hands that to the action bar, so
    # anything short of a fresh mount leaves the buttons live.
    {:cont, socket |> assign_scope(session) |> watch_sessions(:draw_it_again)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = assign_scope(socket, session)

    case socket.assigns.current_scope do
      %{user: %User{}} -> {:cont, watch_sessions(socket, :send_them_to_sign_in)}
      _ -> {:halt, to_login(socket)}
    end
  end

  defp assign_scope(socket, session) do
    user = session["user_token"] && Auth.get_user_by_session_token(session["user_token"])

    Phoenix.Component.assign(socket, :current_scope, %{user: usable(user)})
  end

  # Only worth a subscription on a connected socket: the dead render is one
  # request and is gone before anything could be revoked.
  #
  # Straight to PubSub rather than through `Abuuba.Timelines.Broadcast`, which
  # every other subscriber here uses. That one keeps a per-topic listener count
  # for deciding whether a timeline is worth rendering, and buys it with a
  # `GenServer.call` and a monitor through a single process -- on the connect
  # path of every page, for a count nothing reads on this topic. On a reconnect
  # storm that process is where every socket would queue.
  defp watch_sessions(%{assigns: %{current_scope: %{user: %User{} = user}}} = socket, answer) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(Abuuba.PubSub, Auth.sessions_topic(user.id))

      socket
      |> remember_where(answer)
      |> Phoenix.LiveView.attach_hook(:session_revoked, :handle_info, fn
        {:sessions, :revoked}, socket -> {:halt, answer(answer, socket)}
        _message, socket -> {:cont, socket}
      end)
    else
      socket
    end
  end

  defp watch_sessions(socket, _answer), do: socket

  # Where the reader is, so a public page can send them to it again. Only that
  # answer needs it: a `handle_info` hook is not told the address, and the
  # sign-in page is the same address wherever they were.
  # `socket.router` is nil for a LiveView rendered inside another one, and
  # attaching a `handle_params` hook to one of those raises. Nothing nests a
  # LiveView today; this is so that the first one to do it does not crash at
  # mount for a reason nobody would look for here.
  defp remember_where(%{router: nil} = socket, _answer), do: socket

  defp remember_where(socket, :draw_it_again) do
    Phoenix.LiveView.attach_hook(socket, :session_here, :handle_params, fn _params, uri, socket ->
      {:cont, Phoenix.Component.assign(socket, :session_here, here(uri))}
    end)
  end

  defp remember_where(socket, _answer), do: socket

  # Query string included: a reader on `/search?q=hello` who is drawn again at
  # `/search` has lost their results, which reads as the page having emptied
  # itself.
  defp here(uri) do
    case URI.parse(uri) do
      %URI{path: path, query: nil} -> path
      %URI{path: path, query: query} -> path <> "?" <> query
    end
  end

  defp answer(:send_them_to_sign_in, socket), do: to_login(socket)

  defp answer(:draw_it_again, socket) do
    Phoenix.LiveView.push_navigate(socket, to: socket.assigns[:session_here] || ~p"/")
  end

  defp to_login(socket) do
    socket
    |> Phoenix.LiveView.put_flash(:error, gettext("You have to be signed in to see that page."))
    |> Phoenix.LiveView.redirect(to: ~p"/login")
  end

  defp maybe_write_remember_me(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_me_cookie, token, @remember_me_options)
  end

  defp maybe_write_remember_me(conn, _token, _params), do: conn

  defp ensure_user_token(conn) do
    case get_session(conn, :user_token) do
      nil ->
        conn = fetch_cookies(conn, signed: [@remember_me_cookie])

        case conn.cookies[@remember_me_cookie] do
          nil -> {nil, conn}
          token -> {token, put_session(conn, :user_token, token)}
        end

      token ->
        {token, conn}
    end
  end

  # A fresh session on every sign-in and sign-out. Anything an unauthenticated
  # visitor put in the session must not survive into an authenticated one,
  # which is what session fixation exploits.
  defp renew_session(conn) do
    preserved = Map.take(get_session(conn), ["locale"])

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> then(fn conn ->
      Enum.reduce(preserved, conn, fn {key, value}, acc -> put_session(acc, key, value) end)
    end)
  end

  defp maybe_store_return_to(%{method: "GET", request_path: path} = conn) do
    put_session(conn, :user_return_to, path)
  end

  defp maybe_store_return_to(conn), do: conn

  defp signed_in_path(conn) do
    get_session(conn, :user_return_to) || ~p"/"
  end
end
