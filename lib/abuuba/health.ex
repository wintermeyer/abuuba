defmodule Abuuba.Health do
  @moduledoc """
  Whether this instance can serve a request.

  Separate from the endpoint that reports it, because "can this server work"
  is a question about the server rather than about HTTP — and because a branch
  that only ever runs when the database is down is one that has to be testable
  without taking a database down.
  """

  @doc """
  Whether the database is answering.

  One trivial query with a short deadline. Enough to know the pool has a live
  connection; not enough to be a load anybody notices at one request per second
  forever, which is the rate a load balancer will ask at.

  Any failure at all is a no. A readiness check that answered yes because it
  could not tell would put a server that cannot serve back into rotation, which
  is the one outcome it exists to prevent.
  """
  @spec ready?(module()) :: boolean()
  def ready?(repo \\ Abuuba.Repo) do
    match?({:ok, _result}, repo.query("SELECT 1", [], timeout: 2_000))
  rescue
    _unreachable -> false
  catch
    :exit, _down -> false
  end
end
