defmodule AbuubaWeb.EmailSubscriptionHTML do
  @moduledoc """
  The confirm-or-stop page for email updates.
  """

  use AbuubaWeb, :html

  embed_templates "email_subscription_html/*"

  @doc """
  The name to put in front of somebody, display name for preference.
  """
  def account_name(%{display_name: name}) when is_binary(name) and name != "", do: name
  def account_name(%{username: username}), do: "@" <> username
end
