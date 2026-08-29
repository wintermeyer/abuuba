defmodule AbuubaWeb.HealthController do
  @moduledoc """
  Whether this instance is fit to be sent traffic.

  ## Two questions, two endpoints

  A load balancer and a deploy tool want different answers. "Is the process
  up" decides whether to restart it; "can it serve a request" decides whether
  to route to it. Answering the second when only the first is true is how a
  rolling deploy sends every request to a server whose database is not there
  yet.

  So `/health` says the process is alive and answers without touching anything
  else, and `/health/ready` asks the database and says no when it cannot be
  reached.

  ## Unauthenticated, and deliberately dull

  It is the one endpoint a load balancer hits every few seconds forever, so it
  does no work worth measuring and says nothing worth knowing: no version, no
  counts, no configuration. A health endpoint that lists what is installed is a
  reconnaissance endpoint that also happens to report health.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Health

  @doc """
  The process is running.

  Nothing is checked, on purpose: this answers the question a supervisor asks
  before deciding to restart something, and a check that can fail for an
  unrelated reason would have it restarting a healthy server.
  """
  def alive(conn, _params) do
    text(conn, "ok")
  end

  @doc """
  The process can serve a request.

  One trivial query. Enough to know the connection pool has a live connection
  and the database is answering; not enough to be a load somebody notices at
  one request per second forever.
  """
  def ready(conn, _params) do
    if Health.ready?() do
      text(conn, "ok")
    else
      conn
      |> put_status(503)
      |> text("not ready")
    end
  end
end
