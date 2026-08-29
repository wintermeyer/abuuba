defmodule AbuubaWeb.OAuthAuthorizeController do
  @moduledoc """
  What happens when somebody presses Allow or Cancel on the consent screen.
  """

  use AbuubaWeb, :controller

  alias Abuuba.OAuth
  alias Abuuba.OAuth.Application
  alias Abuuba.OAuth.Scopes

  def create(conn, params) do
    application = OAuth.get_application_by_client_id(params["client_id"])
    redirect_uri = params["redirect_uri"] || ""

    cond do
      is_nil(application) or not Application.registered_redirect_uri?(application, redirect_uri) ->
        # Refuse in place rather than redirecting. Redirecting to an
        # unregistered address, even to report an error, is the open redirect
        # that makes stealing a code possible.
        conn
        |> put_status(:bad_request)
        |> text(gettext("That redirect address is not registered for this application."))

      params["approve"] != "true" ->
        send_back(conn, redirect_uri, %{error: "access_denied"}, params["state"])

      true ->
        grant(conn, application, params, redirect_uri)
    end
  end

  defp grant(conn, application, params, redirect_uri) do
    user = conn.assigns.current_scope.user
    scopes = params["scope"] |> Scopes.parse!() |> Scopes.narrow(application.scopes)

    case OAuth.create_authorization_code(application, user,
           redirect_uri: redirect_uri,
           scopes: scopes,
           code_challenge: presence(params["code_challenge"]),
           code_challenge_method: presence(params["code_challenge_method"])
         ) do
      {:ok, code} ->
        deliver_code(conn, redirect_uri, code, params["state"])

      {:error, :unsupported_challenge_method} ->
        send_back(conn, redirect_uri, %{error: "invalid_request"}, params["state"])

      {:error, _reason} ->
        send_back(conn, redirect_uri, %{error: "invalid_request"}, params["state"])
    end
  end

  # A client with no callback of its own gets the code on screen to copy. That
  # is what the out-of-band URI means, and a redirect to it would go nowhere.
  defp deliver_code(conn, redirect_uri, code, state) do
    if redirect_uri == Application.oob_uri() do
      render(conn, :show_code, code: code, layout: false)
    else
      send_back(conn, redirect_uri, %{code: code}, state)
    end
  end

  # `state` goes back untouched. It is how the client detects a forged
  # callback, so dropping it would disable the client's own CSRF check.
  defp send_back(conn, redirect_uri, payload, state) do
    query = payload |> maybe_put_state(state) |> URI.encode_query()

    redirect(conn, external: append_query(redirect_uri, query))
  end

  defp maybe_put_state(payload, nil), do: payload
  defp maybe_put_state(payload, ""), do: payload
  defp maybe_put_state(payload, state), do: Map.put(payload, :state, state)

  defp append_query(uri, query) do
    separator = if String.contains?(uri, "?"), do: "&", else: "?"

    uri <> separator <> query
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value
end
