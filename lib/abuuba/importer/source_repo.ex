defmodule Abuuba.Importer.SourceRepo do
  @moduledoc """
  A read-only connection to the instance being taken over.

  Not in the supervision tree. The source database belongs to somebody else's
  server, exists only during a migration, and a repo started at boot would try
  to connect on every deploy forever after. `mix abuuba.import` starts it with
  `connect/1`, uses it, and lets it go.
  """

  use Ecto.Repo, otp_app: :abuuba, adapter: Ecto.Adapters.Postgres

  @doc """
  Opens the connection against one URL.

  A small pool and no query logging: this reads somebody's production database
  and should be as quiet a guest as possible.
  """
  @spec connect(String.t()) :: {:ok, pid()} | {:error, term()}
  def connect(url) do
    start_link(url: url, pool_size: 2, log: false)
  end
end
