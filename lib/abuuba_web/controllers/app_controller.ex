defmodule AbuubaWeb.AppController do
  @moduledoc """
  `POST /api/v1/apps`, where a client registers itself.

  Unauthenticated on purpose, and that is Mastodon's design rather than an
  oversight: an app has to have credentials before anybody can sign into it, so
  requiring credentials to get credentials would be circular. It does mean
  anybody can fill this table, which is what the rate limit is for.
  """

  use AbuubaWeb, :controller

  alias Abuuba.OAuth
  alias Abuuba.OAuth.AccessToken

  def create(conn, params) do
    attrs = %{
      name: params["client_name"],
      website: params["website"],
      redirect_uris: redirect_uris(params),
      scopes: params["scopes"] || "read"
    }

    case OAuth.create_application(attrs) do
      {:ok, application, secret} ->
        conn
        |> put_status(:ok)
        |> json(%{
          id: to_string(application.id),
          name: application.name,
          website: application.website,
          redirect_uri: application.redirect_uris,
          redirect_uris: Abuuba.OAuth.Application.redirect_uri_list(application),
          client_id: application.client_id,
          client_secret: secret,
          vapid_key: application.vapid_key
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: error_message(changeset)})
    end
  end

  @doc """
  `GET /api/v1/apps/verify_credentials`: what the token in hand belongs to.
  """
  def verify_credentials(conn, _params) do
    case conn.assigns[:current_token] do
      %AccessToken{application: application} ->
        json(conn, %{
          name: application.name,
          website: application.website,
          vapid_key: application.vapid_key
        })

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: gettext("The access token is invalid.")})
    end
  end

  # Mastodon accepts `redirect_uris` as a list and `redirect_uri` as a
  # newline-separated string, and different clients send different ones.
  defp redirect_uris(%{"redirect_uris" => uris}) when is_list(uris), do: Enum.join(uris, "\n")
  defp redirect_uris(%{"redirect_uris" => uris}) when is_binary(uris), do: uris
  defp redirect_uris(%{"redirect_uri" => uri}) when is_binary(uri), do: uri
  defp redirect_uris(_params), do: ""

  defp error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end
