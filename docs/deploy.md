# Deploying abuuba

Two things run: abuuba and Postgres. There is no Redis, no separate worker
process, no cron, no Elasticsearch. Search is Postgres full-text search,
background jobs are Oban rows in Postgres, and the scheduled work runs inside
the same server that answers requests.

That is the shape of the whole operations story, and everything below is detail
on it.

## What you need

- **Postgres 16 or 17.** CI tests against 16 and the compose file runs 17.
  Older releases may well work — the oldest feature the schema uses is
  generated columns, which is Postgres 12 — but nothing tests them. The
  `pg_trgm` extension has to be available; the official Docker images have it,
  and on Debian it is in `postgresql-contrib`.
- **A host with 2 GB of memory** for a small instance. The beam is not hungry,
  but image processing and a busy federation queue both want room.
- **A reverse proxy that terminates TLS.** Caddy, nginx, or whatever the host
  already runs. abuuba speaks plain HTTP and expects something in front of it.
- **A domain you have decided on.** It goes into every identifier this server
  publishes, and changing it later orphans everything already federated.

## Docker, the reference deployment

`docker-compose.yml` in the repository root is the reference deployment.

```sh
cp .env.example .env
$EDITOR .env                      # see the comments in it; three secrets to generate
docker compose run --rm abuuba bin/abuuba eval 'Abuuba.Release.migrate()'
docker compose up -d
```

Then make the account that can open the admin area. A new database has no
roles, so without this there is nobody who can:

```sh
docker compose exec abuuba bin/abuuba eval \
  'Abuuba.Release.bootstrap_owner(%{username: "alice", email: "alice@example.com"})'
```

It prints a password once and there is nowhere to look it up again. More about
what that account can do, and how to make others, is in
[roles and permissions](admin/roles.md).

**Replacing a Mastodon instance instead of starting an empty one?** Do not run
`docker compose up -d` yet. The takeover brings the accounts and their owners
with it, so it goes between the migration and the first start, and it needs a
few more variables and a mount:
[taking over a Mastodon instance](admin/importing-from-mastodon.md).

Images are published to `ghcr.io/wintermeyer/abuuba` for amd64 and arm64. Tags
are `1.2.3`, `1.2`, `edge` (the current main), `sha-<commit>`, and `latest` on
the newest release. Until the first release is tagged, `edge` is the only one
of those that exists. Pin one in `.env` rather than tracking a moving tag, so
a restart is never an upgrade you did not choose.

Then point your proxy at `127.0.0.1:4000`. A Caddyfile is two lines:

```
social.example.com {
  reverse_proxy 127.0.0.1:4000
}
```

## systemd, without Docker

`rel/abuuba.service` and `rel/abuuba.env.example` are a working unit and its
environment file. Build the release on a machine with the same OS and
architecture as the server (`MIX_ENV=prod mix release`), copy
`_build/prod/rel/abuuba` to `/opt/abuuba`, and:

```sh
sudo useradd --system --home /var/lib/abuuba --create-home abuuba
sudo install -d -o abuuba -g abuuba /var/lib/abuuba/uploads
sudo install -m 600 rel/abuuba.env.example /etc/abuuba/abuuba.env
sudo $EDITOR /etc/abuuba/abuuba.env
sudo -u abuuba /opt/abuuba/bin/abuuba eval 'Abuuba.Release.migrate()'
sudo systemctl enable --now abuuba
```

The unit runs abuuba as its own user with most of the filesystem read-only. Keep
that; a server that fetches and processes files from strangers is exactly the
kind of program those restrictions exist for.

Replacing a Mastodon instance on this machine? The takeover goes between the
migration and `systemctl enable --now`, and it reads a few more variables from
the same environment file:
[taking over a Mastodon instance](admin/importing-from-mastodon.md).

## Configuration

Everything is read from the environment at boot, by `config/runtime.exs`. The
full list is in that file, with a comment on each. These are the ones you
cannot start without:

| Variable | What it is |
| --- | --- |
| `DATABASE_URL` | `ecto://user:password@host/database` |
| `SECRET_KEY_BASE` | Signs sessions and tokens. 64+ random bytes. |
| `CLOAK_KEY` | Encrypts private keys and OTP secrets. Base64, 32 bytes. |
| `PHX_HOST` | The hostname this instance is reachable at. |
| `MEDIA_ROOT` | Where uploads are written, unless `MEDIA_STORAGE=s3`. |
| `MAIL_FROM` | The address confirmations and password resets come from. |
| `SMTP_RELAY` | The mail server to send them through, unless `MAIL_ADAPTER` says otherwise. |

`LOCAL_DOMAIN` is worth knowing about even though it has a default. It is the
domain in account addresses and in every id this server publishes, and it
defaults to `PHX_HOST` — set it only when the two differ, and never on an
instance that has already federated anything.

It is also the name outgoing mail identifies itself by: the greeting the relay
sees, and the domain in each message's `Message-ID`. Both would otherwise come
from the machine's own hostname, which in a container is the container id, and
a relay is entitled to refuse a greeting that is not a real domain. Nothing to
configure — it follows `LOCAL_DOMAIN` — but it is a reason the two want to
match what your DNS says about the sending address.

**`CLOAK_KEY` is not recoverable.** Every account's ActivityPub private key and
every two-factor secret is encrypted with it. Lose it and the instance cannot
sign anything it has already published, which is not a state you recover from
by restoring a database backup. Store it somewhere that is not this machine.

Everything else has a default that works: pool size, port, media storage, the
sign-up puzzle, S3, a CDN host, translation. All of it is listed in the
[configuration reference](admin/configuration.md), which also covers the
settings that live in the database rather than the environment.

Two of the defaults are security ones and are worth knowing by name:
`ALLOW_PRIVATE_FEDERATION_ADDRESSES` and `ALLOW_INSECURE_FEDERATION` are both
off, and a public server wants them left that way. The
[configuration reference](admin/configuration.md#two-switches-for-a-closed-test-network)
says what each turns off and why the test suite needs one of them.

### How much CPU the runtime helps itself to

Two variables control how the Erlang VM sizes itself. Both have defaults that
are right on a normal server, and neither needs setting to run abuuba.

| Variable | What it is |
| --- | --- |
| `ABUUBA_SCHEDULERS` | How many schedulers to run. Unset, the release reads the container's CPU quota and uses that, falling back to the machine's core count when there is no quota. |
| `ABUUBA_SCHEDULER_BUSY_WAIT` | `1` restores the VM's default busy-wait. Off otherwise. |

The defaults exist because the VM's own are wrong in a container, in two ways.

It counts the host's cores and starts one scheduler per core, and it does not
read cgroup limits — so a container held to two CPUs on a large machine starts
a scheduler for every core the *host* has, and they contend for the two the
container actually gets. The release reads the quota before the VM starts and
sizes them to it.

And a scheduler with no work spins before it sleeps, so that the next request
does not pay a wake-up. On a machine dedicated to one busy node that is a good
trade. Everywhere else it is CPU burn indistinguishable from load: measured on
an idle instance with no traffic at all, the runtime took four to five cores in
bursts while Postgres sat at zero.

The release turns the spinning most of the way down rather than off. Measured
back to back on one container with the same data, reading a home timeline:

| Busy-wait | Home timeline p50 | Idle CPU peak |
| --- | --- | --- |
| The VM default | 5.59 ms | 487% |
| What abuuba sets | 5.98 ms | 89% |
| Off entirely | 6.26 ms | 79% |

Off entirely buys almost nothing over what abuuba sets, and costs twice as much
latency for it.

Set `ABUUBA_SCHEDULER_BUSY_WAIT=1` if you are running abuuba on hardware of its own
and would rather have the half-millisecond than the idle cores.

## Health endpoints

Two, because a load balancer and a supervisor are asking different questions.

- **`GET /health`** — the process is up. It touches nothing else and cannot
  fail for an unrelated reason. This is what a supervisor should restart on.
- **`GET /health/ready`** — it can serve a request: the database answers.
  Returns `200 ok` or `503 not ready`. This is what a load balancer should
  route on.

Answering the second when only the first is true is how a rolling deploy sends
every request to a container whose database is not reachable yet. Both are
unauthenticated and deliberately dull: no version, no counts, no configuration.
A health endpoint that lists what is installed is a reconnaissance endpoint
that also reports health.

The container image has a `HEALTHCHECK` that asks the readiness question over
`bin/abuuba rpc`, so `docker compose ps` shows it without any HTTP client.

## Migrations, and deploying without downtime

Migrations are a separate command, never part of container start:

```sh
# Docker
docker compose run --rm abuuba bin/abuuba eval 'Abuuba.Release.migrate()'

# systemd
sudo -u abuuba /opt/abuuba/bin/abuuba eval 'Abuuba.Release.migrate()'
```

It creates the database on a first boot and is a no-op on every run after that,
so it is safe to make it the first step of your deploy script unconditionally.

**Where somebody else provisions the database**, use `migrate_only()` instead:

```sh
docker compose run --rm abuuba bin/abuuba eval 'Abuuba.Release.migrate_only()'
```

The difference is one question. `migrate()` asks whether the database exists,
and Ecto answers that by connecting to the `postgres` maintenance database and
looking in `pg_database`. On a cluster where your role may not connect there —
`REVOKE CONNECT ON DATABASE postgres FROM PUBLIC` is a common hardening step —
the question cannot be asked, and a failure to ask looks exactly like an answer
of no: the next thing tried is `CREATE DATABASE`, which also fails, and you get
"could not create the database" about a database that is present and fully
migrated. `migrate_only()` skips the question. If the database really is
missing, you get a connection error naming it, which is the truth.

A container that migrates on start migrates once per replica, all at once. Ecto
locks the `schema_migrations` table so they do not corrupt each other, but the
losers block until the winner finishes, and a slow migration then looks like every container
failing its start timeout at the same moment.

The order that gives you a deploy nobody notices:

1. **Migrate first, with the old version still serving.** This is the whole
   trick, and it only works if the migration is one the old code survives.
2. **Start the new version**, and let readiness decide when it takes traffic.
3. **Stop the old one.** It finishes the requests it is holding; the unit gives
   it 30 seconds.

Which means migrations have to be written so that the version before them still
works against the new schema:

- **Adding** a column, table or index is always safe. Add it, deploy code that
  writes it, and only then deploy code that reads it as required.
- **Removing** takes two releases. Stop using it, ship that, then drop it in
  the next one. A column dropped in the same release that stops writing it is a
  column the old container is still selecting during the overlap.
- **Renaming** is add, backfill, switch, drop — four steps, three of them
  boring. There is no safe single-step rename.
- **Backfilling** a large table belongs in an Oban job rather than a migration.
  A migration holds a lock and blocks the deploy; a job runs behind it.
- **`CREATE INDEX CONCURRENTLY`** for an index on a table with real data in it,
  with `@disable_ddl_transaction true` and `@disable_migration_lock true`. The
  plain form locks writes for as long as it takes to build.

To go back, `Abuuba.Release.rollback/2` takes the repo and the version to step
down to:

```sh
bin/abuuba eval 'Abuuba.Release.rollback(Abuuba.Repo, 20260101120000)'
```

Rolling back the code is usually the better move. A rollback that drops a
column drops the data in it.

## Scheduled work: nothing else to run

Every recurring job runs inside the abuuba process, on Oban's cron. There is no
crontab to install and no second container to schedule. If abuuba is running, all
of this is happening:

| Schedule | What it does |
| --- | --- |
| every minute | Publishes scheduled posts |
| every minute | Tells people a poll they voted in has closed |
| every minute | Publishes and expires announcements |
| every 5 minutes | Recomputes trending tags, posts and links |
| every 15 minutes | Trims home and list feeds back to their cap |
| hourly | Sweeps expired idempotency keys |
| hourly (:20) | Retries and expires pending translations |
| hourly (:30) | Deletes suspended accounts whose grace window passed |
| daily (03:15) | Closes registrations on a server nobody is moderating |
| daily (03:45) | Vacuums cached remote media, once a retention is set |
| daily (04:15) | Deletes other servers' posts past their retention, once one is set |
| daily (04:45) | Deletes uploads nobody posted, once they are a day old |

The list lives in `config/config.exs` under `Oban` and each worker's module doc
says why it runs when it does. The two vacuums are the ones that do nothing
until an admin configures something: each needs its own retention period set
before it deletes anything, and both are zero out of the box. The orphan sweep
after them needs no setting, because an upload with no post and no owner is not
something anybody chose to keep -- it is a file the server is holding by
accident.

Running more than one abuuba container is fine. Oban's cron takes a lock so a
job scheduled for a given minute runs once across the cluster, not once per
container.

## Backups

Three things, and only three:

1. **The database.** `pg_dump` on a schedule you can live with losing.
2. **`MEDIA_ROOT`** (or the S3 bucket). Remote media in it is a cache and can
   be lost; local uploads cannot, and other servers have already linked to
   them.
3. **`CLOAK_KEY` and `SECRET_KEY_BASE`.** Not on this host. See above for what
   losing the first one means.

Restoring is the same three in that order, then `Abuuba.Release.migrate()`.

## When something is wrong

```sh
docker compose logs -f abuuba            # or: journalctl -u abuuba -f
curl -s localhost:4000/health/ready    # 503 means it cannot reach Postgres
bin/abuuba remote                        # an IEx shell attached to the running node
```

The admin area has the operational views: federation health per domain, the
job queue, reports, and rate limits. Those are documented in
[`docs/admin/`](admin/), starting with [the admin area](admin/admin-area.md).
