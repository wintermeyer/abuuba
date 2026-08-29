import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/abuuba start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :abuuba, AbuubaWeb.Endpoint, server: true
end

config :abuuba, AbuubaWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :abuuba, AbuubaWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/abuuba_web/router\.ex$"E,
        ~r"lib/abuuba_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

# ## Translation
#
# Outside the production block on purpose: an admin evaluating abuuba should be
# able to point a development server at LibreTranslate without a release build.
#
# Off unless a provider is named. `TRANSLATION_PROVIDER=deepl` needs
# `DEEPL_API_KEY`; a free key ends in `:fx` and is detected, so the host does
# not have to be set. `TRANSLATION_PROVIDER=libretranslate` needs
# `LIBRETRANSLATE_ENDPOINT` and, on most instances, `LIBRETRANSLATE_API_KEY`.

case System.get_env("TRANSLATION_PROVIDER") do
  "deepl" ->
    config :abuuba, translation_provider: Abuuba.Translation.DeepL

    config :abuuba, Abuuba.Translation.DeepL,
      api_key: System.fetch_env!("DEEPL_API_KEY"),
      host: System.get_env("DEEPL_HOST")

  "libretranslate" ->
    config :abuuba, translation_provider: Abuuba.Translation.LibreTranslate

    config :abuuba, Abuuba.Translation.LibreTranslate,
      endpoint: System.fetch_env!("LIBRETRANSLATE_ENDPOINT"),
      api_key: System.get_env("LIBRETRANSLATE_API_KEY")

  _ ->
    :ok
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  # Refusing to boot is the point. Starting with a generated or default key
  # would encrypt every private signing key under something the operator does
  # not have, and the damage only surfaces on the next restart when nothing
  # decrypts any more.
  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise """
      environment variable CLOAK_KEY is missing.
      It encrypts private signing keys at rest. Generate one with:

          openssl rand -base64 32

      That works on a release, where there is no Mix. From a checkout,
      `mix abuuba.gen.cloak_key` does the same thing.

      Keep it with your other secrets and back it up: losing it means every
      local account has to be re-keyed and re-federated.
      """

  # AES-256 needs exactly 32 bytes. Base.decode64! accepts any length, so a key
  # generated with the wrong byte count boots happily and then crashes on the
  # first registration, which is a long way from the mistake.
  decoded_cloak_key = Base.decode64!(cloak_key)

  byte_size(decoded_cloak_key) == 32 ||
    raise """
    CLOAK_KEY decodes to #{byte_size(decoded_cloak_key)} bytes, but AES-256
    needs exactly 32. Generate one with: openssl rand -base64 32
    """

  config :abuuba, Abuuba.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: decoded_cloak_key}
    ]

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :abuuba, Abuuba.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # ## The name this server calls itself
  #
  # It goes into every id this server publishes — actors, activities, posts —
  # and it cannot be taken from the request, because a request arriving on some
  # other hostname would otherwise make us claim actors under it.
  #
  # LOCAL_DOMAIN so that a server reachable at `abuuba.example.com` can still
  # hand out `@name@example.com` addresses, which is the usual reason the two
  # differ. It defaults to PHX_HOST, which is what most deployments want.
  #
  # Changing either one on a running instance orphans everything already
  # federated: other servers have stored the old ids and will not look for new
  # ones.
  config :abuuba,
    local_domain: System.get_env("LOCAL_DOMAIN") || host,
    local_scheme: System.get_env("URI_SCHEME", "https")

  # Two switches that exist for a closed test network and nothing else, both
  # off unless the environment says otherwise.
  #
  # ALLOW_PRIVATE_FEDERATION_ADDRESSES turns off the check that refuses to
  # fetch anything on a private network. That check is the SSRF guard: a
  # federation fetch is aimed by what a stranger's document said, and following
  # one into 127.0.0.1 or 169.254.169.254 hands them the inside of the machine.
  # The interop suite needs it off because a Docker bridge is entirely private.
  #
  # ALLOW_INSECURE_FEDERATION lets a fetch go over plain HTTP, which is
  # readable and rewritable by anything in between.
  #
  # Neither belongs on a server anybody else can reach.
  config :abuuba,
    allow_private_federation_addresses:
      System.get_env("ALLOW_PRIVATE_FEDERATION_ADDRESSES") == "true",
    allow_insecure_federation: System.get_env("ALLOW_INSECURE_FEDERATION") == "true"

  config :abuuba, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :abuuba, AbuubaWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :abuuba, AbuubaWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :abuuba, AbuubaWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Where media lives
  #
  # Local disk by default, under `MEDIA_ROOT`. Set `MEDIA_STORAGE=s3` and the
  # bucket variables to use an S3-compatible service instead; `S3_ENDPOINT` is
  # for everything that speaks the protocol without being AWS.
  #
  # `MEDIA_ALIAS_HOST` puts a CDN in front of either one. It is the host
  # clients are sent to, and it has to reach both backends: a local-disk server
  # behind a cache is as ordinary as an S3 one.

  if root = System.get_env("MEDIA_ROOT") do
    config :abuuba, media_root: root
  else
    if System.get_env("MEDIA_STORAGE") != "s3" do
      raise """
      environment variable MEDIA_ROOT is missing.

      It is the directory uploads are written to. Without it they would go to a
      temporary directory, which on most systems is emptied on reboot — and the
      loss is silent until somebody notices every avatar has gone.

      Point it at a volume that is backed up:

          MEDIA_ROOT=/var/lib/abuuba/uploads

      Or set MEDIA_STORAGE=s3 and the bucket variables to keep media off this
      machine entirely.
      """
    end
  end

  if System.get_env("MEDIA_STORAGE") == "s3" do
    config :abuuba, media_storage: Abuuba.Media.Storage.S3

    config :abuuba, Abuuba.Media.Storage.S3,
      bucket: System.fetch_env!("S3_BUCKET"),
      region: System.get_env("S3_REGION", "us-east-1"),
      endpoint: System.get_env("S3_ENDPOINT"),
      access_key_id: System.fetch_env!("S3_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("S3_SECRET_ACCESS_KEY")
  end

  if host = System.get_env("MEDIA_ALIAS_HOST") do
    config :abuuba, media_alias_host: host
  end

  # ## The sign-up puzzle
  #
  # Off unless both are set. A server that quietly required a puzzle nobody
  # configured would refuse every sign-up with no explanation.
  #
  #     config :abuuba, Abuuba.Moderation.Signup.Captcha,
  #       site_key: System.get_env("HCAPTCHA_SITE_KEY"),
  #       secret: System.get_env("HCAPTCHA_SECRET")

  if System.get_env("HCAPTCHA_SITE_KEY") && System.get_env("HCAPTCHA_SECRET") do
    config :abuuba, Abuuba.Moderation.Signup.Captcha,
      site_key: System.get_env("HCAPTCHA_SITE_KEY"),
      secret: System.get_env("HCAPTCHA_SECRET")
  end

  # ## Mail
  #
  # Confirmations, password resets and approval notices all go out by mail, so
  # an instance that cannot send it cannot sign anybody up. The default in
  # `config/config.exs` is Swoosh's local adapter, which keeps mail in memory
  # for a developer to look at and delivers nothing — silently, which is why
  # this refuses to start rather than defaulting to it.
  sender_email =
    System.get_env("MAIL_FROM") ||
      raise """
      environment variable MAIL_FROM is missing.

      It is the address confirmations and password resets are sent from, and it
      has to be one the receiving side will accept for your domain:

          MAIL_FROM=noreply@example.com
      """

  config :abuuba, sender_email: sender_email

  # The API adapters below are HTTP clients. Req is already here.
  config :swoosh, :api_client, Swoosh.ApiClient.Req

  case System.get_env("MAIL_ADAPTER", "smtp") do
    "smtp" ->
      config :abuuba, Abuuba.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay:
          System.get_env("SMTP_RELAY") ||
            raise("""
            environment variable SMTP_RELAY is missing.

            It is the mail server to hand outgoing mail to. Set it along with
            SMTP_USERNAME and SMTP_PASSWORD, or pick another transport with
            MAIL_ADAPTER=mailgun.
            """),
        port: String.to_integer(System.get_env("SMTP_PORT", "587")),
        username: System.get_env("SMTP_USERNAME"),
        password: System.get_env("SMTP_PASSWORD"),
        # The name this server greets the relay with. Left unset, gen_smtp uses
        # the machine's own hostname, which inside a container is the container
        # id: a bare token with no dot in it. A relay that insists on a
        # fully-qualified name in EHLO -- Postfix's `reject_non_fqdn_helo`, and
        # it is not unusual -- refuses the whole session, so no mail goes out
        # at all and the reason is in the relay's log rather than in ours.
        hostname: (System.get_env("LOCAL_DOMAIN") || host) |> String.split(":") |> hd(),
        # `if_available` rather than `always`, because a relay on localhost
        # usually has no certificate and refusing to use it would be the wrong
        # answer for the deployment where the mail never leaves the machine.
        tls: :if_available,
        auth: :if_available,
        retries: 2

    "mailgun" ->
      config :abuuba, Abuuba.Mailer,
        adapter: Swoosh.Adapters.Mailgun,
        api_key: System.fetch_env!("MAILGUN_API_KEY"),
        domain: System.fetch_env!("MAILGUN_DOMAIN")

    "local" ->
      # Deliberate, and only useful for trying the software out: mail is kept
      # in memory and nobody receives anything. Nothing signs up successfully
      # on a server in this mode unless an admin approves them by hand.
      config :abuuba, Abuuba.Mailer, adapter: Swoosh.Adapters.Local

    other ->
      raise "MAIL_ADAPTER is #{inspect(other)}; it has to be one of smtp, mailgun or local"
  end

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :abuuba, Abuuba.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
