defmodule Abuuba.Federation.URIsProfileUrlTest do
  @moduledoc """
  Every account has an address a reader can click, including the ones this
  server knows almost nothing about.
  """

  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.URIs

  describe "profile_url/1" do
    test "a local account is a page on this server" do
      account = account_fixture(%{username: "hedwig"})

      assert URIs.profile_url(account) == "#{URIs.base_url()}/@hedwig"
    end

    test "a remote account is whatever page it published" do
      account = %Account{
        username: "hedwig",
        domain: "far.example",
        url: "https://far.example/users/hedwig"
      }

      assert URIs.profile_url(account) == "https://far.example/users/hedwig"
    end

    test "a remote account with no page falls back to its actor id" do
      account = %Account{
        username: "hedwig",
        domain: "far.example",
        uri: "https://far.example/ap/hedwig"
      }

      assert URIs.profile_url(account) == "https://far.example/ap/hedwig"
    end

    test "a remote account with neither still has an address here" do
      # A row this server made from a mention or a follower list and has not
      # fetched yet. It used to raise, which took down every page that showed
      # one of its posts.
      account = %Account{username: "hedwig", domain: "far.example"}

      assert URIs.profile_url(account) == "#{URIs.base_url()}/@hedwig@far.example"
    end
  end
end
