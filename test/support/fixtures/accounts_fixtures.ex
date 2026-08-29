defmodule Abuuba.AccountsFixtures do
  @moduledoc """
  Fixtures for `Abuuba.Accounts`.
  """

  alias Abuuba.Accounts

  def unique_username, do: "user#{System.unique_integer([:positive])}"
  def unique_email, do: "#{unique_username()}@example.com"

  @doc """
  A local account: no domain, and no `uri`.

  Passing a `uri` here is almost always a mistake. Nothing in the running
  server ever sets one on a local account — the id it publishes is derived
  from the row by `Abuuba.Federation.Actor.id/1` — so a fixture that sets one
  gives the test a shape production does not have. That is how every inbound
  activity addressed to a local account came to be silently dropped while the
  whole inbound test suite stayed green: the lookups matched on a column the
  fixtures filled in and production leaves `NULL`.
  """
  def account_fixture(attrs \\ %{}) do
    {:ok, account} =
      attrs
      |> Enum.into(%{username: unique_username()})
      |> Accounts.create_account()

    account
  end

  @doc """
  A remote account, living on `domain`.
  """
  def remote_account_fixture(attrs \\ %{}) do
    domain = Map.get(attrs, :domain, "remote.example")

    attrs
    |> Enum.into(%{
      domain: domain,
      uri: "https://#{domain}/users/someone",
      inbox_url: "https://#{domain}/users/someone/inbox"
    })
    |> account_fixture()
  end

  def user_fixture(attrs \\ %{}) do
    account_id = Map.get_lazy(attrs, :account_id, fn -> account_fixture().id end)

    {:ok, user} =
      attrs
      |> Enum.into(%{account_id: account_id, email: unique_email()})
      |> Accounts.create_user()

    user
  end
end
