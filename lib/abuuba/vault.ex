defmodule Abuuba.Vault do
  @moduledoc """
  Encryption at rest for the few columns that hold secrets.

  Right now that is the private half of an account's signing keypair. A private
  key is the account's identity on the fediverse: anyone holding it can sign
  activities as that account, on any server that trusts it. A database dump, a
  stray backup or a read-only SQL injection would otherwise hand that over for
  every local account at once, so the key never reaches a disk in the clear.

  The encryption key itself comes from the environment in production, never
  from the repository. See `config/runtime.exs`.

  ## Rotating the key

  Add a new cipher under a **new tag** and leave the old one in the list as a
  fallback. Do not swap the key under the existing `AES.GCM.V1` tag: Cloak
  picks the cipher to decrypt with by matching that tag, so it would choose the
  new key for rows written with the old one, and its AES.GCM implementation
  reports a failed decryption as the bare atom `:error` rather than raising. A
  swap therefore looks like it worked and quietly returns nonsense for every
  existing row. `Abuuba.Accounts.Keypair.undecryptable?/1` exists to catch that
  case and say so out loud.
  """

  use Cloak.Vault, otp_app: :abuuba
end
