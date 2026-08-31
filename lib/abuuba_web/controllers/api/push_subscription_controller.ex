defmodule AbuubaWeb.API.PushSubscriptionController do
  @moduledoc """
  `/api/v1/push/subscription`.

  One subscription per access token, so `POST` replaces rather than adds. One
  token is one app on one device, and a device that subscribes again is telling
  us its old endpoint is dead.

  `PUT` changes which types a device wants without re-registering it, which
  matters because re-registering means a new endpoint from the browser and a
  window where notifications go nowhere.
  """

  use AbuubaWeb, :controller

  alias Abuuba.WebPush
  alias Abuuba.WebPush.VAPID
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities

  plug AbuubaWeb.Plugs.RequireUser

  plug AbuubaWeb.Plugs.RequireScopes, ["push"] when action in [:show, :create, :update, :delete]

  def show(conn, _params) do
    case WebPush.get_subscription(conn.assigns[:current_token]) do
      nil -> API.error(conn, 404, "Record not found")
      subscription -> json(conn, Entities.push_subscription(subscription))
    end
  end

  def create(conn, params) do
    account = current_account(conn)

    if VAPID.configured?() do
      store(conn, account, params)
    else
      # Saying so plainly beats accepting a subscription that will never be
      # delivered to and leaving somebody wondering why their phone is quiet.
      API.error(conn, 422, "Validation failed: this server cannot send push notifications")
    end
  end

  defp store(conn, account, params) do
    case WebPush.subscribe(conn.assigns[:current_token], account, attrs(params)) do
      {:ok, subscription} ->
        json(conn, Entities.push_subscription(subscription))

      {:error, changeset} ->
        API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
    end
  end

  def update(conn, params) do
    case WebPush.get_subscription(conn.assigns[:current_token]) do
      nil ->
        API.error(conn, 404, "Record not found")

      subscription ->
        case WebPush.update_subscription(subscription, data_attrs(params)) do
          {:ok, updated} ->
            json(conn, Entities.push_subscription(updated))

          {:error, changeset} ->
            API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
        end
    end
  end

  def delete(conn, _params) do
    case WebPush.get_subscription(conn.assigns[:current_token]) do
      nil -> json(conn, %{})
      subscription -> WebPush.unsubscribe(subscription) && json(conn, %{})
    end
  end

  # The shape a browser's PushManager produces, which is what every client
  # forwards verbatim.
  defp attrs(params) do
    subscription = params["subscription"] || %{}
    keys = subscription["keys"] || %{}

    %{
      "endpoint" => subscription["endpoint"],
      "key_p256dh" => keys["p256dh"],
      "key_auth" => keys["auth"]
    }
    |> Map.merge(data_attrs(params))
  end

  defp data_attrs(params) do
    data = params["data"] || %{}

    %{}
    |> put_alerts(data["alerts"])
    |> put_policy(data["policy"])
  end

  defp put_alerts(attrs, alerts) when is_map(alerts) do
    Map.put(attrs, "alerts", Map.new(alerts, fn {key, value} -> {key, API.truthy?(value)} end))
  end

  defp put_alerts(attrs, _alerts), do: attrs

  defp put_policy(attrs, policy) when is_binary(policy), do: Map.put(attrs, "policy", policy)
  defp put_policy(attrs, _policy), do: attrs
end
