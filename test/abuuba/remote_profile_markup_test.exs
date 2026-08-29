defmodule Abuuba.RemoteProfileMarkupTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Statuses.Formatter

  describe "another server's profile markup" do
    test "a bio is cleaned when the actor arrives" do
      # The bio and the fields are HTML written by somebody we have no reason
      # to trust, and both are rendered into a reader's page.
      {:ok, account} =
        Accounts.create_account(%{
          username: "carol",
          domain: "remote.example",
          uri: "https://remote.example/users/carol",
          note: "<p>hello</p><script>alert(1)</script>"
        })

      refute account.note =~ "script"
      assert account.note =~ "hello"
    end

    test "a field value is cleaned too" do
      {:ok, account} =
        Accounts.create_account(%{
          username: "dave",
          domain: "remote.example",
          uri: "https://remote.example/users/dave",
          fields: [
            %{name: "Site", value: ~S|<a href="https://d.example" onclick="steal()">d</a>|}
          ]
        })

      [field] = account.fields

      refute field.value =~ "onclick"
      assert field.value =~ "d.example"
    end

    test "our own bio is left as the plain text it is" do
      # A local bio is not markup. Cleaning it would turn a typed "<3" into
      # nothing at all.
      {:ok, account} = Accounts.create_account(%{username: "alice", note: "I like <3 and code"})

      assert account.note == "I like <3 and code"
    end

    test "our own bio is escaped when it is rendered" do
      account = account_fixture(%{note: "<script>alert(1)</script>"})

      refute Formatter.to_html(account.note) =~ "<script>"
    end
  end
end
