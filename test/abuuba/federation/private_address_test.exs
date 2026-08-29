defmodule Abuuba.Federation.PrivateAddressTest do
  @moduledoc """
  Whether this server will talk to an address on a private network.

  Refusing is the default and the only safe one: a fetch is aimed by whatever
  the network told us, and a server that follows a name into 127.0.0.1 or
  169.254.169.254 hands a stranger the inside of the machine.

  Allowing it is for a closed test network — the federation interop suite runs
  four servers on a Docker bridge, where every address is private and nothing
  can be reached at all with the guard on.
  """

  use ExUnit.Case, async: false

  alias Abuuba.Federation.HTTP.Address

  setup do
    on_exit(fn -> Application.delete_env(:abuuba, :allow_private_federation_addresses) end)

    :ok
  end

  describe "by default" do
    test "a private address is refused" do
      refute Address.public?({172, 17, 0, 2})
      refute Address.public?({127, 0, 0, 1})
      refute Address.public?({169, 254, 169, 254})
    end

    test "and a public one is not" do
      # The positive control: a guard that refused everything would satisfy
      # every assertion above.
      assert Address.public?({93, 184, 216, 34})
    end
  end

  describe "when the server is told to allow them" do
    setup do
      Application.put_env(:abuuba, :allow_private_federation_addresses, true)

      :ok
    end

    test "a private address is allowed" do
      assert Address.public?({172, 17, 0, 2})
      assert Address.public?({127, 0, 0, 1})
    end

    test "and a caller can still refuse one for itself" do
      # The option beats the setting, so a call site that must never reach a
      # private address keeps that guarantee.
      refute Address.public?({172, 17, 0, 2}, allow_private: false)
    end
  end
end
