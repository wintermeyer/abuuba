defmodule AbuubaWeb.OAuthController do
  @moduledoc """
  The `/oauth/*` endpoints.

  Error bodies follow RFC 6749: a machine-readable `error` and a human
  `error_description`. Clients switch on the first and show the second, so
  inventing our own shape here would break both halves at once.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Federation.Actor
  alias Abuuba.Media.ProfileImages
  alias Abuuba.OAuth
  alias Abuuba.OAuth.Application
  alias Abuuba.OAuth.Scopes

  @doc """
  Exchanges a grant for a token.
  """
  def token(conn, %{"grant_type" => "authorization_code"} = params) do
    with {:ok, application} <- authenticate_client(params),
         {:ok, token, raw} <-
           OAuth.exchange_authorization_code(params["code"] || "",
             application: application,
             redirect_uri: params["redirect_uri"],
             code_verifier: params["code_verifier"]
           ) do
      json(conn, token_response(token, raw))
    else
      {:error, reason} -> oauth_error(conn, reason)
    end
  end

  def token(conn, %{"grant_type" => "client_credentials"} = params) do
    with {:ok, application} <- authenticate_client(params),
         {:ok, scopes} <- requested_scopes(params, application) do
      {:ok, token, raw} = OAuth.issue_client_credentials_token(application, scopes)

      json(conn, token_response(token, raw))
    else
      {:error, reason} -> oauth_error(conn, reason)
    end
  end

  # Named explicitly rather than falling through, so that a client asking for
  # the password grant is told it is unsupported instead of being told its
  # request was malformed.
  def token(conn, %{"grant_type" => grant}) when grant in ~w(password implicit refresh_token) do
    oauth_error(conn, :unsupported_grant_type)
  end

  def token(conn, _params), do: oauth_error(conn, :unsupported_grant_type)

  @doc """
  Revokes a token.
  """
  def revoke(conn, params) do
    case authenticate_client(params) do
      {:ok, application} ->
        OAuth.revoke_presented_token(application, params["token"] || "")

        # RFC 7009: a revocation of a token that does not exist is still a
        # success, so the endpoint cannot be used to test whether one is valid.
        json(conn, %{})

      {:error, reason} ->
        oauth_error(conn, reason)
    end
  end

  @doc """
  RFC 8414 metadata, so a client can discover the endpoints rather than having
  them hardcoded.
  """
  def metadata(conn, _params) do
    json(conn, %{
      issuer: url(~p"/"),
      authorization_endpoint: url(~p"/oauth/authorize"),
      token_endpoint: url(~p"/oauth/token"),
      revocation_endpoint: url(~p"/oauth/revoke"),
      app_registration_endpoint: url(~p"/api/v1/apps"),
      scopes_supported: Scopes.known(),
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "client_credentials"],
      token_endpoint_auth_methods_supported: ["client_secret_basic", "client_secret_post"],
      code_challenge_methods_supported: ["S256"],
      service_documentation: "https://docs.joinmastodon.org/api/oauth-scopes/"
    })
  end

  @doc """
  Who the bearer of this token is, as OpenID Connect asks it.

  The same account a client already gets from `verify_credentials`, under the
  field names a single-sign-on library expects. Some of those libraries will
  not talk to a server that does not answer here at all, which is the whole
  reason this exists rather than a second way of asking the same question.

  `sub` is the account id and not the username: a name can be changed and a
  subject identifier may not, or every system that trusted this one would
  quietly follow the rename to whoever holds the name next.
  """
  def userinfo(conn, _params) do
    case current_account(conn) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_token"})

      account ->
        json(conn, %{
          sub: to_string(account.id),
          name: account.display_name,
          preferred_username: account.username,
          profile: Actor.id(account),
          picture: ProfileImages.url(account, :avatar)
        })
    end
  end

  defp authenticate_client(params) do
    application = OAuth.get_application_by_client_id(params["client_id"])

    cond do
      is_nil(application) -> {:error, :invalid_client}
      OAuth.valid_client_secret?(application, params["client_secret"]) -> {:ok, application}
      true -> {:error, :invalid_client}
    end
  end

  defp requested_scopes(params, application) do
    case Scopes.parse(params["scope"]) do
      {:ok, requested} -> {:ok, Scopes.narrow(requested, application.scopes)}
      {:error, _unknown} -> {:error, :invalid_scope}
    end
  end

  defp token_response(token, raw) do
    %{
      access_token: raw,
      token_type: "Bearer",
      scope: token.scopes,
      created_at: DateTime.to_unix(token.inserted_at)
    }
  end

  defp oauth_error(conn, reason) do
    {status, error, description} = describe(reason)

    conn
    |> put_status(status)
    |> json(%{error: error, error_description: description})
  end

  defp describe(:invalid_client),
    do: {401, "invalid_client", gettext("Client authentication failed.")}

  defp describe(:invalid_grant),
    do:
      {400, "invalid_grant",
       gettext("The authorization code is invalid, expired, or already used.")}

  defp describe(:invalid_verifier),
    do: {400, "invalid_grant", gettext("The code verifier does not match the challenge.")}

  defp describe(:invalid_scope),
    do: {400, "invalid_scope", gettext("One of the requested scopes is not recognised.")}

  defp describe(:unsupported_grant_type),
    do:
      {400, "unsupported_grant_type",
       gettext("Only authorization_code and client_credentials are supported.")}

  defp describe(:invalid_redirect_uri),
    do: {400, "invalid_request", gettext("The redirect URI is not registered for this app.")}

  defp describe(:unsupported_challenge_method),
    do: {400, "invalid_request", gettext("Only the S256 code challenge method is supported.")}

  defp describe(_other),
    do: {400, "invalid_request", gettext("The request could not be handled.")}

  @doc false
  def oob_uri, do: Application.oob_uri()
end
