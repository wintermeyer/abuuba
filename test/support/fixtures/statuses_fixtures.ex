defmodule Abuuba.StatusesFixtures do
  @moduledoc """
  Fixtures for `Abuuba.Statuses`.
  """

  import Abuuba.AccountsFixtures

  alias Abuuba.Statuses

  def status_fixture(attrs \\ %{}) do
    account_id = Map.get_lazy(attrs, :account_id, fn -> account_fixture().id end)

    {:ok, status} =
      attrs
      |> Enum.into(%{account_id: account_id, text: "hello"})
      |> Statuses.create_status()

    status
  end

  def tag_fixture(name \\ nil) do
    {:ok, tag} = Statuses.upsert_tag(name || "tag#{System.unique_integer([:positive])}")
    tag
  end

  def conversation_fixture(uri \\ nil) do
    {:ok, conversation} = Statuses.upsert_conversation(uri)
    conversation
  end
end
