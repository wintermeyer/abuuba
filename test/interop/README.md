# Federation interop

```
test/interop/run.sh              against everything available
test/interop/run.sh mastodon     against one
```

The servers are published on the host so the scenarios can drive them, on
4000, 3000 and 8080 by default. Those are ordinary ports for a working machine
to be using — 4000 doubly so, since it is abuuba's own dev port and
`mix phx.server` is what you are most likely to have running while working on
federation. Move them if they clash:

```
ABUUBA_INTEROP_PORT=4100 MASTODON_INTEROP_PORT=3100 GOTOSOCIAL_INTEROP_PORT=8180 \
  test/interop/run.sh
```

The run checks them before starting anything and names the one that is taken.

Docker and python3, which every machine that can run this already has. It
brings up abuuba and every implementation whose image
can be pulled on one network, makes an account on each, runs every scenario
that applies, writes a matrix to `test/interop/results/report.md`, and tears
everything down.

An implementation whose image cannot be pulled is reported as skipped and the
others still run. That is not a nicety: an unpullable image fails
`docker compose up` for every service at once, so abuuba's own container never
started either and a run ended with no report — no results for anybody, and a
red tick that looked like an abuuba defect rather than somebody else's registry
going away. Akkoma is out of the suite for exactly that reason; the note in
`compose.yml` says what it would take to put it back.

## Why this exists

The fediverse punishes protocol drift silently. Nothing returns an error when
two servers stop agreeing: posts do not arrive, follows sit unaccepted, and the
first anybody hears is a person saying they cannot see somebody. Unit tests
cannot catch that, because both sides of a unit test are written by the same
people.

It runs nightly rather than per push, because most of what it catches is a
change in somebody *else's* release.

## What is checked

The list lives in `Abuuba.Interop.Suite` and a unit test asserts it still covers
everything: follows in both directions and against a locked account, post
propagation, replies, boosts, edits, deletes, media, content warnings, polls
and votes, quote requests, Move, domain blocks, signature verification in both
directions, and authorized fetch.

Most of it runs in the direction that is harder to get right: the peer acts and
abuuba has to read the activity correctly. A peer boosts, favourites, replies to
and mentions abuuba's posts; a peer blocks, forwards a report, migrates, edits and
deletes. The scenarios named `*_in` are the ones whose outbound twin exists
separately, not the only inbound ones — checking a direction by the file's name
rather than by what it does gets this backwards.

Each scenario is a small shell script in `scenarios/` that drives real HTTP and
exits 0 or 1 with a reason. They use the Mastodon client API, which all four
servers implement — that is what keeps them readable and what makes them the
same test against each server.

A scenario names which implementations it applies to. Asking a server about a
feature it does not have produces a failure that means nothing, so the matrix
shows `·` instead.

## Reading the matrix

Three outcomes: **pass**, **fail**, and **not run**. The third is deliberate —
collapsing it into either of the others is how a suite quietly stops testing
something. Failures are listed under the matrix with the reason, because a
table cell is not somewhere to read a sentence.

Nothing in the report says which server is wrong. A failure is a place where
abuuba and that implementation do not agree, and which of them is at fault is a
question this suite does not try to answer.

## When an await gives up

"The post never arrived" has three quite different causes and one message, so
a scenario that gives up prints all three sides before it fails:

- **abuuba's delivery queue** — how many jobs are in each state, and what the
  newest one did. Nothing queued, still retrying, and delivered are three
  different bugs.
- **the peer's queues** — depths, plus the newest retrying and dead job with
  its class, its arguments and its error. Counts alone say a job failed and
  not why, and Sidekiq's backoff is the same shape as ours: a job that has
  failed three times is more than two minutes from its next attempt, which is
  the whole window a scenario waits.
- **the proxy** — read live from the container, filtered to the scenario's own
  marker where one can be found in the polling command, then the last few
  deliveries either way. This is the only place that knows whether a request
  crossed at all.

And one thing worth knowing before reading any of it. The occurrence that
prompted these reports showed abuuba having delivered all thirteen of its jobs,
every one on the first attempt, which was read as "the post was sent, so the
question is the other server's". It was not. Those thirteen were deliveries to
somebody else; the post being waited for had no job at all, because abuuba had
no follower to make one for — `domain_block` had severed the follow and the
peer went on believing it still followed, so the precondition reported green.
A queue report can only show the jobs that exist, and the decisive case is the
job that was never created, which looks exactly like a healthy queue.

So read the delivery queue for whether *this* post was queued, not for whether
the queue is busy: `[{"completed", 13}]` with nothing pending is as consistent
with "nothing to send" as with "everything sent".

## Adding an implementation

One file in `implementations/`, defining `PEER_ID`, `PEER_NAME`, `PEER_DOMAIN`,
`PEER_URL`, `PEER_ACCOUNT`, and two functions: `peer_create_account` (prints an
access token) and `peer_version`. Add the service to `compose.yml` and the
implementation to `Abuuba.Interop.Suite`. Nothing else knows the difference.

## What has not been verified yet

**Nobody has run this end to end.** It was written on a machine where the
Docker daemon is not reachable, so the parts that could be checked offline were
— every scenario parses, the suite list is asserted by a unit test, and the
matrix renderer is tested against recorded runs — and the parts that need live
servers have not been.

Specifically, treat these as unverified until a run says otherwise:

- **`implementations/gotosocial.sh` and `implementations/akkoma.sh`.** Akkoma
  is not in the compose file at all, so its file is reference rather than
  something that runs. The
  account-creation commands are from each project's documented admin CLI, but
  the exact flags have not been exercised. The runner reports an implementation
  whose account cannot be created as a skipped column with the reason, so a
  wrong flag shows up as one clear line rather than a column of misleading
  failures.
- **The image tags in `compose.yml`.** Pinned deliberately; they will need
  bumping, and a version that no longer exists fails at `docker compose up`
  rather than subtly.
- **The `move` scenario** needs a second account on the peer to move to and
  currently skips unless `PEER_MOVE_TARGET` is set.

The first person to run this should expect to fix a flag or two. That is the
normal state of a harness like this, and it is why the failures are reported
with reasons rather than as a count.
