defmodule Mix.Tasks.Abuuba.Gen.CloakKey do
  @shortdoc "Generates a key for encrypting private signing keys at rest"

  @moduledoc """
  Prints a fresh 256-bit key, base64 encoded, for `CLOAK_KEY`.

      $ mix abuuba.gen.cloak_key

  Keep it wherever you keep your other production secrets, and back it up.
  Losing it does not just lock you out of the column: every local account's
  signing key becomes unrecoverable, so every account has to be re-keyed and
  the new keys re-federated to every server that has seen them.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    32 |> :crypto.strong_rand_bytes() |> Base.encode64() |> Mix.shell().info()
  end
end
