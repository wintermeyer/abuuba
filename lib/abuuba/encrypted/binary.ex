defmodule Abuuba.Encrypted.Binary do
  @moduledoc """
  An Ecto type for a binary column whose contents are encrypted by `Abuuba.Vault`.

  The column is a plain `:binary` in the database and the value is a plain
  string in the struct. Everything in between is the vault's business.
  """

  use Cloak.Ecto.Binary, vault: Abuuba.Vault
end
