# abuuba

[![CI](https://github.com/wintermeyer/abuuba/actions/workflows/ci.yml/badge.svg)](https://github.com/wintermeyer/abuuba/actions/workflows/ci.yml)

> **Version 1.0. Do not run this in production.** It has bugs nobody has found
> yet, and it has never run a real community. Put it on a lab machine, break
> it, and tell me what broke.

abuuba is a fediverse server written in [Elixir](https://elixir-lang.org) and
[Phoenix](https://www.phoenixframework.org). It speaks
[Mastodon](https://joinmastodon.org)'s protocols: [ActivityPub](https://www.w3.org/TR/activitypub/)
for federation and the complete [Mastodon client API](https://docs.joinmastodon.org/client/intro/)
for apps. Every one of the 289 endpoints Mastodon 4.6 declares under `/api/v1`
and `/api/v2` is answered here, a test fails the build when one goes missing,
and existing apps work unchanged. It exists for one reason: Mastodon is too
slow. I needed a fast peer to test [vutuv](https://vutuv.de), my ultrafast
business network, against, and Mastodon could not keep up.

| Same machine, same data, same Postgres | abuuba | Mastodon | |
| --- | ---: | ---: | ---: |
| Home timeline p50 | 7.37 ms | 85.83 ms | **12x faster** |
| Home timeline p99 | 17.81 ms | 292.10 ms | **16x faster** |
| Public timeline p50 | 5.33 ms | 76.71 ms | **14x faster** |
| Public timeline p99 | 11.45 ms | 204.23 ms | **18x faster** |
| Fan-out to the last of 10,000 followers | 830 ms | 56,874 ms | **68x faster** |

Medians of three runs on 28 August 2026 against Mastodon v4.4.7, both servers
on one bare-metal box: 2x AMD EPYC 9254, 96 threads, 1.0 TiB DDR5, Debian 13,
Postgres 17.10 on both sides from the same untuned image.

That is one instance. What decides how many a host can carry is a different set
of numbers, and they compound:

| Per instance | abuuba | Mastodon | |
| --- | ---: | ---: | ---: |
| Memory, idle | 725 MB | 1,175 MB | **1.6x smaller** |
| Restart, until it answers again | 2,695 ms | 4,816 ms | **1.8x faster** |
| Docker Containers | 2 | 5 | **2.5x fewer** |

And the browser code, which is the same story told in a third way: 453 lines of
JavaScript against 97,209, with no npm dependencies at all against a lockfile
of 1,428 entries.

None of which is an argument for replacing Mastodon. This is the
[nginx](https://nginx.org) and [Apache](https://httpd.apache.org) story. Apache
was good software and still is; nginx turned up because a different shape of
load arrived and an architecture built for the older one could not bend that
far. The part worth remembering is what happened next: nginx did not kill
Apache, it made Apache faster and better. That is what I hope abuuba does for
Mastodon. If a server twelve times quicker on the same hardware pushes
Mastodon to close that gap, the fediverse wins twice, and I will count that as
the best thing this project ever did.

## Why abuuba exists

I reinvented a perfectly good wheel. Here is why.

I am the founder of [vutuv](https://vutuv.de), a business network. Think of it
as an open source LinkedIn alternative that talks to the fediverse as well. It
is fast on purpose, and testing it means driving federation through a real
ActivityPub peer every day. A peer that cannot keep up drags the whole loop
down to its own speed, and for a long time that peer was Mastodon.

Mastodon could not keep up. Seeding a peer with a thousand followers and two
hundred posts took fifteen minutes; abuuba does it in thirty-nine seconds.
Mastodon is just too slow.

That is not a complaint about Mastodon, and not a complaint about
[Ruby on Rails](https://rubyonrails.org). I love Rails. It is a pleasure to
write and it has earned every bit of its reputation. Hell, I wrote books about
Ruby on Rails! But Phoenix/Elixir is faster, and
not by a little, and the [BEAM](https://www.erlang.org/) was built to run one
system across several machines: nodes find each other and pass messages as
ordinary work, with no Redis in the middle and no separate job runner to keep in
step. Rails reaches the same place by adding those pieces and then keeping them
alive. On the BEAM it is the runtime's own job, which is why an abuuba instance
is one application and one Postgres database and nothing else.

So I wrote abuuba. The wheel was perfectly good. It was just too heavy for the
cart I was building.

— Stefan Wintermeyer

## A note on the age this was built in

I could not have done this a year ago. Not the design, which is not novel, and
not the protocols, which are written down. The volume. abuuba is about 84,000
lines of application code with 63,000 lines of tests behind it, 4,347 of them,
plus a federation suite that drives real Mastodon and GoToSocial containers
through 32 scenarios, an admin area, a Mastodon importer, a benchmark harness
and 6,500 lines of documentation in two languages. That is a team's output for
a year. I am one person and wrote abuuba as a side project to improve the
development of vutuv.

Agentic coding closed that gap, [Claude Code](https://claude.ai/code)
specifically. The interesting part is not that it writes code quickly. It is
that it will do the tedious correct thing every time: sweep every call site
rather than the three you remembered and write the test before the fix.

That is the shift worth naming. Not that software writes itself. That one person
can now hold a project to standards that used to need a team to enforce, and can
prove it to you rather than ask you to take their word.

## Naming and License

I am not a fan of the AGPL that the Mastodon project uses. From my consulting
work I know that many companies have trouble running AGPL software, because
they are not set up to give changes back to the community. So I prefer MIT,
which makes life easier for everybody.

During the time mastodons lived — roughly 5 million to 10,000 years ago — one of
the fastest mammals in North America was Miracinonyx, the so-called American
cheetah. So I initially wanted to call this project "Miracinonyx", but who can
remember that? I looked through my stack of registered but unused domain names
instead, and went with abuuba.

## Not for the faint of heart

This is version 1.0. It has bugs, and nobody knows yet where they are: it has
never served real members on the open internet, and nobody but me has tested
any of it. Mastodon's bugs have had a decade and thousands of admins to
surface them; abuuba's have had me. Every number above is measured and
reproducible, and that is all it says.

**Do not put abuuba into production right now.** Not under a community you
would be sorry to lose, not under accounts somebody depends on. Run it in a
lab, break it, and tell me what broke.

The documentation is in this repository: a deployment guide, twenty-two pages
for administrators, ten for users and ten more in German. What does not exist
is everything that grows around software once other people run it. No forum
thread from someone who hit your problem three years ago, no tutorial written
by a stranger, no answer waiting for the question you have not thought to ask
yet. Mastodon has had nearly ten years to accumulate that, and it is worth more
than a feature list.

**If you are new to running a fediverse server, run Mastodon.** It is good
software, it is documented by thousands of people, and when it breaks at two in
the morning somebody has already written down what to do.

Try abuuba if you need the speed and an Elixir stack trace is something you can
work with. Even then it is a toy for now, on a machine where losing everything
costs you nothing.

## Getting started for Developers

You need Postgres on `localhost` and the Erlang and Elixir versions pinned in
`.tool-versions`; `mise install` fetches them. Media processing wants **ffmpeg**
on the path; without it video, audio and animated uploads are recorded as failed
and everything else still works. On Linux add **inotify-tools**, or the dev
server logs an error about it on every start that is only live reload.

```
mix setup
mix phx.server
```

The server answers on [localhost:4000](http://localhost:4000); override
`PGUSER` and `PGPASSWORD` if yours are not the `postgres` default. The first
account registered on an empty database becomes an admin, and nothing is
emailed in development: everything the server would have sent lands in
[the mailbox](http://localhost:4000/dev/mailbox), linked from every page.

## Running it for real

abuuba and Postgres, and nothing else. No Redis, no worker process, no cron;
scheduled work runs inside the server that answers requests.

```
cp .env.example .env          # three secrets to generate; the comments say how
docker compose run --rm abuuba bin/abuuba eval 'Abuuba.Release.migrate()'
docker compose up -d
```

Images are published for amd64 and arm64. Without Docker there is a release and
a systemd unit in `rel/`. Configuration, health endpoints, the zero-downtime
migration order and what to back up are in [deploying abuuba](docs/deploy.md).

## Coming from Mastodon

`mix abuuba.import` reads a live instance's database, checks everything that has
to be true, and reports what a takeover would move, writing nothing until asked.
Accounts, their owners, signing keys and OAuth credentials come across keeping
their ids, so links keep resolving, passwords keep working and the app on
somebody's phone stays signed in. `--verify` proves it against the old database
afterwards. Back up both databases before `--execute`: that run is not
reversible, and the way back from an import that went wrong is a restore.

On a server there is no Mix, so the same command is a function in the release,
and on the reference deployment it is the line the migration already uses:

```
docker compose run --rm abuuba bin/abuuba eval 'Abuuba.Release.import_mastodon()'
```

See [taking over a Mastodon instance](docs/admin/importing-from-mastodon.md)
for the variables it needs, the mount the media comes through and the order the
steps go in; the short version is that the domain has to stay the same.

## Performance

A claim that one server is faster than another is worth exactly what the
ability to check it is worth, so the harness lives in this repository and the
numbers do not live in a blog post:

```
mix abuuba.bench                    # both servers, about 25 minutes
bash bench/run.sh --startup-only    # restart timing alone, about 5
```

Docker and nothing else. It starts abuuba and a pinned Mastodon side by side,
seeds both with the same generated data, warms them, settles both databases so
neither is measured against work Postgres has not finished, and writes a report
with the numbers and the machine they came from. The methodology, and where the
two stacks genuinely differ, are in [bench/README.md](bench/README.md).

Four things to hold against the tables at the top. The host was shared with
unrelated work, which is why the run was repeated three times; the ratios held
across all three, and a run that began at a load average of 12 moved the
restart figure by 0.3%. Mastodon's home timeline carries about 12% of
run-to-run variability at both sizes measured, which is why these are medians
and not one run's numbers. One row, idle CPU, gave five answers across two
profiles that disagreed about the direction and was left out rather than
published. And 150 requests at concurrency 4 measures latency, not throughput.

Every figure here was also taken on a 96-thread server. But 725 MB fits on a
Raspberry Pi too.

The restart row is the modest one, and it should not be read with the others as
one factor. Starting up is runtime and code loading, where a BEAM release and a
booted Rails application are in the same order of magnitude. The timeline rows
measure a storage and fan-out design, which is where an order of magnitude comes
from. It is also a floor: it stops and starts containers that already exist, so
a deploy that changes the image costs both sides more.

And it is the slower of two real numbers. Restarting a stack that has been up
twenty minutes with data in it comes out around 2,590 ms, consistently below
every measurement of a freshly built empty one, which is the opposite of what
you would guess. The figure above is the empty-database one, quoted because it
is the less flattering. Which of uptime or data causes the difference is not
yet known, and the table will say so until it is.

## Development

`mix precommit` is the gate, and CI runs the same alias against a Postgres 16
service: warnings as errors, formatting, unused dependencies, Credo in strict
mode, and 4,347 tests. It only reports, so run `mix format` yourself.

The project site is `site/`, plain HTML and CSS with no build step, published
to [abuuba.com](https://abuuba.com) by GitHub Pages on every push to `main`. The German Impressum and
Datenschutzerklärung it needs live there too, as does the press kit
(`site/press.html` and the logo and screenshot files under `site/press/`).

Federation is checked against the real thing rather than a mock.
`test/interop/run.sh` brings up abuuba, Mastodon 4.4.7 and
[GoToSocial](https://gotosocial.org) 0.19.1 in Docker and drives 32 scenarios
against both peers, from follows and boosts through polls, media, edits, blocks
in both directions, reports and account migration. That is 58 runs, since not
every scenario applies to both, and it is what the federation half of the
compatibility claim at the top rests on. The last run was 58 passing with none failing. Nothing has yet served real members on the open internet.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) first. The short version: Mastodon is
AGPL-3.0 and abuuba is MIT, so you may read Mastodon to learn how the protocols
behave, and you may never copy anything out of it.

## License

MIT. See [LICENSE](LICENSE).
