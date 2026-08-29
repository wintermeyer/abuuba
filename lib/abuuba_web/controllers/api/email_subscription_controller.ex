defmodule AbuubaWeb.API.EmailSubscriptionController do
  @moduledoc """
  `POST /api/v1/accounts/:account_id/email_subscriptions`, an address asking to
  hear from somebody.

  Open to anybody, because the person subscribing is usually not a member here
  and that is the point of the feature. What keeps it from being a way to mail
  strangers is on the other side: nothing at all is sent to an address that has
  not confirmed, and the confirmation is one message.

  `404` where the account does not take subscribers, whether because the server
  has the feature off, because the account has, or because it is not the sort
  of account that could. Three different reasons for one answer, deliberately:
  telling them apart tells somebody probing which accounts here are worth
  probing further. The refusal happens behind the rate limiter rather than in
  front of it, so probing costs the prober their budget.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts
  alias Abuuba.EmailSubscriptions
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities

  plug AbuubaWeb.Plugs.APIRateLimit, bucket: :email_subscription

  def create(conn, %{"account_id" => account_id} = params) do
    # Parsed before it reaches a query. This route is unauthenticated, so a
    # path segment that is not an id must be a 404 rather than a cast error
    # anybody passing by can raise.
    account = account_id |> API.parse_id() |> account()
    email = params |> Map.get("email", "") |> to_string()

    case subscribe(account, email, Gettext.get_locale(AbuubaWeb.Gettext)) do
      :ok ->
        json(conn, %{})

      {:error, %Ecto.Changeset{} = changeset} ->
        API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))

      {:error, :closed} ->
        API.error(conn, 404, "Record not found")
    end
  end

  defp account(nil), do: nil
  defp account(id), do: Accounts.get_account(id)

  defp subscribe(nil, _email, _locale), do: {:error, :closed}
  defp subscribe(account, email, locale), do: EmailSubscriptions.subscribe(account, email, locale)
end
