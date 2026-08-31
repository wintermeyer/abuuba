import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :abuuba, Abuuba.Repo,
  username: System.get_env("PGUSER") || "postgres",
  password: System.get_env("PGPASSWORD") || "postgres",
  hostname: "localhost",
  database: "abuuba_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # Capped so the pool stays sane on many-core machines, where the
  # unbounded default can exceed the server's max_connections.
  pool_size: min(System.schedulers_online() * 2, 16)

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :abuuba, AbuubaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "P6yfGzR/9fl8NYAlL3t7cJX1TGu9JKdXBUVjSMhg2iBj7bkcsOf6FXuZE3SE0n3q",
  server: false

# In test we don't send emails
config :abuuba, Abuuba.Mailer, adapter: Swoosh.Adapters.Test

# The year in review is open for a fortnight each December. Reading the real
# calendar would make the feature testable only in December and would make this
# suite fail on New Year's Eve, so the window is pinned here and each test says
# which side of it it is on.
config :abuuba, :annual_report_campaign, :never

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# A fixed, deliberately public key: test data is throwaway and a developer
# should never have to set an environment variable to run the suite. Production
# reads its key from the environment, see config/runtime.exs.
config :abuuba, Abuuba.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("3Jnb0hZiHIzHTOih7t2cTEPEpY98Tu1wvA0yXCETFg0=")}
  ]

# Deliberately weak: hashing is the slowest thing in the suite at production
# cost, and no test asserts anything about how expensive it is.
config :bcrypt_elixir, log_rounds: 1

# The host this server calls itself in every URI it hands to other servers.
# Never taken from the request: a request arriving on another hostname would
# otherwise make us claim actors under it.
config :abuuba, local_domain: "abuuba.test", local_scheme: "http"

# Jobs run inline in tests, so a test asserts on the result rather than on a
# queue having been written to.
config :abuuba, Oban, testing: :manual

# Every test transaction is its own world; a cache surviving across two of
# them would leak one test's settings into another. Correctness never depends
# on the cache being on — that is the cache's contract.
config :abuuba, cache_enabled: false

# The notifications page coalesces a burst of arrivals into one redraw. Zero
# here so a test does not wait on a real clock: the flag and the message are
# the same, only the window is gone.
config :abuuba, notifications_coalesce_ms: 0

# The delivery breaker's cooling-off period, a minute in production. Asking
# what it does on both sides of that gate is worth milliseconds, not a minute,
# and a test that reads the real clock here would be a test nobody runs.
config :abuuba, federation_circuit_cooldown_ms: 40

# The instance actor is built by the first test that needs it, not at boot:
# the sandbox owns every connection and a write from the application process
# would not belong to any test.
config :abuuba, ensure_instance_actor: false

# The suite never touches DNS: see `Abuuba.TestDNS`.
config :abuuba, :address_resolver, {Abuuba.TestDNS, :resolve}
