# Benchmarking abuuba against Mastodon

```
mix abuuba.bench                    # 1k followers, a few minutes
mix abuuba.bench --profile medium   # 10k
mix abuuba.bench --profile large    # 100k, and it takes a while

bash bench/run.sh --startup-only    # restart timing alone, about five minutes
```

Docker and nothing else. The harness starts both servers from their own images,
seeds them with the same generated data, warms them up, measures, tears
everything down, and writes `bench/results/<profile>.md`.

## Restart timing on its own

`--startup-only` brings both stacks up, migrates them, and measures nothing but
how long each takes to answer after being stopped and started again. No seeding,
which is where the other twenty-five minutes go.

It is a restart, not a cold start. The image is already pulled, the container
already created and the page cache already warm, so a real first deploy is
slower than this on both sides. Symmetric, so the comparison holds; just not a
claim about starting from nothing.

It also measures an **empty** database. `--startup-only` exits before the seed,
which is the point of it, so the figure it produces is a restart with nothing
in Postgres. That is not what an instance does in production, and the two are
not obviously the same number.

To measure a restart against a seeded stack, do not reach for
`--startup-only --keep`: it will exit before seeding and answer the same
question again. Let a real run seed and leave the stacks up, then invoke the
measurement directly against them:

```
bash bench/run.sh medium --keep
bench/measure/startup.sh "abuuba seeded"   bench/compose/abuuba.yml   "abuuba" \
  http://localhost:4000/health
bench/measure/startup.sh "mastodon seeded" bench/compose/mastodon.yml "web sidekiq streaming" \
  http://localhost:3005/health
docker compose -f bench/compose/abuuba.yml   down -v
docker compose -f bench/compose/mastodon.yml down -v
```

`--keep` disables the teardown trap, hence the two `down -v` lines. Note that
calling `startup.sh` directly is exactly the case where `run.sh`'s `export
LC_ALL=C` does not reach it, which is why that script pins the locale itself:
on a host with a comma decimal separator it would otherwise emit JSON nothing
can parse.

Boot time is code loading and a supervision tree coming up, not a function of
how many rows are in the database, so the seed has nothing to tell us about it.
The measurement restarts the application tier only and leaves Postgres alone:
starting a database costs the same on both sides.

It is not a symmetrical restart, and that is the point rather than a flaw.
abuuba's application tier is one container, because background jobs and
streaming run inside the same VM as the web server. Mastodon's is three. The
clock stops when the web container answers `/health`, which does not wait for
Sidekiq to be ready to run a job — generous to Mastodon, and abuuba has no
equivalent state to be generous about.

## Why this is in the repository

"A lot faster" is a claim about somebody else's software, and a claim like that
is worth exactly as much as the ability to check it. Every published benchmark
is somebody's own numbers on their own machine; these are too. The difference
is that you can produce your own on the hardware you would actually run this
on, and disagree with a number by pointing at the run that produced it.

## The rules it holds itself to

**Same machine, same time.** Both stacks are brought up on the host running the
script. Neither is given a warm page cache the other does not have, because the
run starts from nothing every time — no volumes, no leftover database.

**Same Postgres.** Both sides get `postgres:17-alpine`. A comparison where one
side has a newer database is a comparison of database versions.

**Out of the box on both sides.** No tuning, no cache in front, no changed
worker counts, no indexes added for the occasion. The one thing set that a real
server would not set is a fixed secret on each side, because a benchmark that
asked for one could not be started with one command.

**The same healthcheck on both sides.** Docker keeps probing a container for
as long as it runs, and the probe's cost lands in the same cgroup the resource
measurements read. Both stacks are therefore probed with an HTTP GET on the
same interval. abuuba used to be probed with `bin/abuuba rpc`, which boots a second
BEAM and throws it away: it charged abuuba for a whole VM start every three
seconds and made the idle-CPU row a comparison of probes rather than of
servers.

**A warm-up before anything is timed.** A cold first request measures module
loading, an empty query plan cache and a runtime that has not seen the code
yet. Both sides get the same warm-up pass, and it is not measured.

**A settled database before anything is timed.** Seeding leaves Postgres with
unvacuumed pages, stale planner statistics and an unfinished checkpoint, and
how much of that background work is done when measuring starts would otherwise
depend on how long the queue drain happened to take. Both databases get an
explicit `VACUUM (ANALYZE)` and `CHECKPOINT` after the drain, so the
measurements start from the same state however fast the queues emptied.

**The same data, in the same order.** Described once, in
`Abuuba.Bench.Dataset`, and written by two seeders that produce exactly the same
handles: `bench/seed/abuuba.exs` and `bench/seed/mastodon.rb`. If you change one,
change the other; the report prints the dataset description and the seed so a
reader can see which data a run used.

**Percentiles, not averages.** A mean latency hides the tail, and the tail is
what people notice.

**A failed measurement is reported, not omitted.** Silence in a comparison
reads as "no difference".

## Where the two stacks genuinely differ

These are differences in what each server *requires*, and hiding them would
make the numbers less true rather than more fair.

- **Mastodon runs five containers** (web, Sidekiq, streaming, Postgres, Redis).
  **abuuba runs two** (the app, Postgres). The resource measurements add up every
  container in each stack, so Redis and Sidekiq count against Mastodon —
  because an admin has to run and pay for them.
- **Mastodon's compose file here is close to the one it publishes**, with the
  changes needed to start unattended: fixed secrets, no volumes, log level
  raised, and no Elasticsearch (abuuba has no equivalent to compare it against).
- **The images are pinned.** Mastodon's version is in
  `bench/compose/mastodon.yml` and appears in the report.

## What is measured

| | What it means |
| --- | --- |
| Home timeline p50/p99 | The read every client makes on every refresh |
| Fan-out | How long until the **last** follower can see a new post — not how long the API call takes, which is milliseconds on both sides because both queue the work |
| Public timeline p50/p99 | The read a logged-out visitor and every relay makes |
| Post page, logged out | What a link from elsewhere costs to serve |
| Memory and CPU | The whole stack, idle and under the measured load |

## Reading a report

Each measurement stands on its own, with both sides next to each other and the
ratio spelled out. There is deliberately no single "N times faster" figure: the
ratios differ per measurement, and an average across them would hide the one
you care about.

**A figure in brackets is the range of the samples behind it.** CPU is a rate
over a window, so it is sampled several times and reported as a median. Where
those samples disagreed, the row says so: `3.9 % (0.6–86.8)` is a median with
no answer underneath it, and the ratio on that row is not worth quoting. A
wide range on an idle reading usually means a periodic job fired inside the
sampling window rather than that the stack costs that much to have running.

## Re-rendering without running

```
mix abuuba.bench --report-only --raw bench/results/small --out report.md
```

The raw JSON each measurement wrote stays in `bench/results/<profile>/`, so a
report can be regenerated, or one produced from somebody else's run.

## If it will not start

- **"The Docker daemon is not reachable."** On Linux your user usually needs to
  be in the `docker` group, and the group only applies to a new login session.
- **The abuuba image will not build.** The Elixir and OTP versions are pinned in
  `Dockerfile` to what `.tool-versions` says. If hexpm has not
  published that combination, pass `--build-arg ELIXIR_VERSION=...`.
- **Mastodon's migrations take a long time on the first run.** They do. The
  images are cached afterwards.
