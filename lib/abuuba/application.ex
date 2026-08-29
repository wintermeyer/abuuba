defmodule Abuuba.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  alias Abuuba.Federation.InstanceActor

  @impl true
  def start(_type, _args) do
    children = [
      AbuubaWeb.Telemetry,
      # Before the Repo: nothing may read or write an encrypted column before
      # the vault holding its key is up.
      Abuuba.Vault,
      Abuuba.Repo,
      {Oban, Application.fetch_env!(:abuuba, Oban)},
      Abuuba.RateLimit,
      Abuuba.Federation.HTTP.CircuitBreaker,
      # Our own connection pool rather than the default one. Delivery is the
      # heaviest user of outbound HTTP by a wide margin, and a TLS handshake
      # per delivery to a server we are about to talk to fifty more times is
      # most of the cost of talking to it at all.
      {DNSCluster, query: Application.get_env(:abuuba, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Abuuba.PubSub},
      # After PubSub, whose broadcasts carry its invalidations between nodes.
      Abuuba.Cache,
      # After PubSub, which it wraps, and before the endpoint, whose sockets
      # subscribe through it the moment they connect.
      Abuuba.Timelines.Broadcast,
      # Start a worker by calling: Abuuba.Worker.start_link(arg)
      # {Abuuba.Worker, arg},
      # Start to serve requests, typically the last entry
      AbuubaWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Abuuba.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      ensure_instance_actor()

      {:ok, pid}
    end
  end

  # Built here rather than by whichever peer asks for it first.
  #
  # It is created on demand, and on a fresh server that demand comes from a
  # stranger's request -- which pays a quarter of a second for it, and worse,
  # races any other peer asking at the same moment: the id is fixed, so one of
  # the two loses the insert and gets a 500. A server in authorized-fetch mode
  # fetches this actor to check a signature and shuts abuuba out for five minutes
  # after a single failure, so that narrow race is expensive out of all
  # proportion to its width.
  #
  # After the supervisor, because it needs the repo. Failures are swallowed on
  # purpose: a server that cannot reach its database at boot has a problem this
  # is not, and refusing to start over it would take the web interface down
  # too, including the page that would say so.
  defp ensure_instance_actor do
    if Application.get_env(:abuuba, :ensure_instance_actor, true) do
      InstanceActor.ensure!()
    end
  rescue
    error ->
      Logger.warning("could not build the instance actor at startup: #{inspect(error)}")
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AbuubaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
