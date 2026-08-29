defmodule Abuuba.Repo do
  use Ecto.Repo,
    otp_app: :abuuba,
    adapter: Ecto.Adapters.Postgres
end
