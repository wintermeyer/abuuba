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
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    user = session["user_token"] && Auth.get_user_by_session_token(session["user_token"])

    {:cont, Phoenix.Component.assign(socket, :current_scope, %{user: user})}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    case session["user_token"] && Auth.get_user_by_session_token(session["user_token"]) do
      %User{} = user ->
        {:cont, Phoenix.Component.assign(socket, :current_scope, %{user: user})}

      _ ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(
           :error,
           gettext("You have to be signed in to see that page.")
         )
         |> Phoenix.LiveView.redirect(to: ~p"/login")}
    end
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
