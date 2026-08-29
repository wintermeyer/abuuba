defmodule Abuuba.Repo.Migrations.AddKeyIdToKeypairs do
  @moduledoc """
  The id a peer's key calls itself, kept as the peer wrote it.

  A signature names its key and nothing else, and which actor that belongs to
  was worked out here by cutting the id at `#`. That is right for
  `https://host/users/alice#main-key` and wrong for
  `https://host/users/alice/main-key`, which is what GoToSocial writes: the cut
  gives back the key's own URL, no account has that as its uri, and every
  delivery from every such server was refused as an unknown key.

  So the string the peer signs with is stored rather than reconstructed.

  Nullable, and no backfill. Every key already here was stored by a peer whose
  id shape the old derivation could read -- otherwise it would never have
  verified anything and would not be here -- and the resolver keeps that
  derivation as its second answer. A row without this column goes on working;
  it gets the column the next time its actor is refetched.
  """

  use Ecto.Migration

  def change do
    alter table(:keypairs) do
      add :key_id, :string
    end

    # Looked up on every inbound signed request, which on a busy server is
    # every request that matters.
    create index(:keypairs, [:key_id])
  end
end
