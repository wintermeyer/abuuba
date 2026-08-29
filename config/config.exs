# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Two queues, kept apart on purpose: a backlog of outgoing posts to a slow peer
# must not stall the processing of things arriving. Delivery gets the larger
# concurrency because most of its time is spent waiting on other servers.
# The formats this server takes that the MIME library does not know by name.
# `allow_upload` refuses an extension it cannot resolve to a type, so an
# audio format missing from here is one nobody can attach.
config :mime, :types, %{
  "audio/ogg" => ["ogg"],
  "audio/flac" => ["flac"],
  "audio/mp4" => ["m4a"]
}

config :abuuba, Oban,
  repo: Abuuba.Repo,
  # `media` is its own queue and deliberately narrow: transcoding a video is
  # minutes of CPU where everything in `ingress` is milliseconds of database
  # work, and one long video must not hold a slot inbound federation needs.
  queues: [ingress: 20, push: 50, media: 4],
  plugins: [
    # A minute is finer than anybody schedules to, and the sweep is one query
    # when nothing is due.
    {Oban.Cron,
     crontab: [
       {"* * * * *", Abuuba.Statuses.ScheduledWorker},
       # A poll's whole point arrives after the post does, so the people
       # waiting for the answer are told within the minute.
       {"* * * * *", Abuuba.Statuses.PollExpiryWorker},
       {"0 * * * *", Abuuba.Statuses.IdempotencySweeper},
       # Feeds are allowed to run over their cap between sweeps; see
       # `Abuuba.Timelines.MaintenanceWorker` for why that is cheaper than
       # trimming on every insert.
       {"*/15 * * * *", Abuuba.Timelines.MaintenanceWorker},
       # Suspended accounts whose grace window has passed. Hourly is fine: the
       # window is measured in days and nothing depends on the exact minute.
       {"30 * * * *", Abuuba.Moderation.PurgeWorker},
       # Often enough that a trend appears while it still is one; see
       # `Abuuba.Trends` for why it is recomputed rather than maintained.
       {"*/5 * * * *", Abuuba.Trends.RankWorker},
       # A minute is finer than anybody schedules an announcement to.
       {"* * * * *", Abuuba.Instance.AnnouncementWorker},
       # Once a day is often enough for a decision measured in a week.
       {"15 3 * * *", Abuuba.Moderation.Signup.UnattendedWorker},
       # Remote media is a cache; see `Abuuba.Media.VacuumWorker` for why this is
       # off until an admin sets a retention.
       {"45 3 * * *", Abuuba.Media.VacuumWorker},
       # Half an hour after the media vacuum, so two sweeps with a backlog do
       # not compete for the same disk. Off until a retention is set.
       {"15 4 * * *", Abuuba.Statuses.RemoteVacuumWorker},
       # An upload nobody posted is a file the server is holding by accident,
       # so this one needs no setting to turn it on. Last of the three sweeps.
       {"45 4 * * *", Abuuba.Media.OrphanWorker},
       # One query when there is nothing to do; see the worker for why it runs
       # at all.
       {"20 * * * *", Abuuba.Translation.SweepWorker},
       # Profile links are re-read weekly; the sweep runs hourly and takes a
       # bounded batch, so the work spreads across the day instead of arriving
       # in one burst that every linked site notices at once.
       {"50 * * * *", Abuuba.Accounts.LinkVerificationWorker},
       # Refresh rows carry their own expiry precisely so something can delete
       # them on a timestamp rather than on a cache eviction nobody controls.
       {"40 * * * *", Abuuba.AsyncRefreshes.SweepWorker},
       # Addresses that never confirmed. Daily, because the window is a week.
       {"10 4 * * *", Abuuba.EmailSubscriptions.PurgeWorker},
       # Account archives past their day. Hourly rather than daily: the file is
       # somebody's whole account and the expiry is measured in days, so the
       # cost of checking often is one query and the cost of checking rarely is
       # a day of it sitting there after it should have gone.
       {"25 * * * *", Abuuba.Exports.SweepWorker},
       # Everybody's own instruction to delete their old posts, a batch at a
       # time; see `Abuuba.Statuses.Cleanup` for why it is not one transaction.
       {"35 * * * *", Abuuba.Statuses.CleanupWorker},
       # Sign-in history, which exists to answer "was that me last Tuesday"
       # rather than to be an archive of somebody's whereabouts.
       {"55 4 * * *", Abuuba.Accounts.LoginActivitySweepWorker},
       # The webhook delivery log, which answers "is this working" and "when
       # did it stop" and reaches back no further than a week.
       {"5 5 * * *", Abuuba.Webhooks.SweepWorker}
     ]}
  ]

config :abuuba,
  ecto_repos: [Abuuba.Repo],
  generators: [timestamp_type: :utc_datetime]

# What `mix abuuba.import` runs, in the order it runs them. Listed here rather
# than inside the runner so that a step added later cannot be left out of it.
config :abuuba, :import_steps, [
  Abuuba.Importer.Identity,
  Abuuba.Importer.Content,
  Abuuba.Importer.Graph,
  Abuuba.Importer.Instance,
  Abuuba.Importer.MediaFiles,
  Abuuba.Importer.Rebuild
]

# Configure the endpoint
config :abuuba, AbuubaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AbuubaWeb.ErrorHTML, json: AbuubaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Abuuba.PubSub,
  live_view: [signing_salt: "yzJmUmm+"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :abuuba, Abuuba.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  abuuba: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  abuuba: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
