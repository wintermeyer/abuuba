# Rate limits

Two different things share the name, and telling them apart is most of what an
admin needs to know when somebody reports being blocked.

## Request limits

How fast anyone may call the API. These exist to keep one client from costing
the server more than everybody else combined, and they reset on a fixed
schedule whatever the caller does.

| Who | Allowance |
|---|---|
| A signed-in account, across all their apps | 1500 requests / 5 min |
| One app's token | 300 requests / 5 min |
| Anyone not signed in, per address | 300 requests / 5 min |
| Media uploads, per account | 30 / 30 min |
| Sign-ups, per address | 5 / 30 min |
| App registrations, per address | 5 / 10 min |
| Deletions, per account | 30 / 30 min |
| Email subscriptions, per address | 5 / hour |

An authenticated request counts against the account **and** the token. That is
deliberate: an account with six apps should not get six times the budget, and
one badly written app should not be able to spend the whole account's.

The first three rows apply to every API request. The rest are attached to the
endpoints they name, and each is counted on top of the general budget rather
than instead of it: an upload spends one from the media allowance and one from
the account's 1,500.

Two of them are counted per account rather than per address, because the thing
being bounded is what a person does rather than where a request came from.
Those two are the exception to the account-and-token rule below: they are
counted against the account only, so one of a person's apps can spend the whole
account's upload or deletion allowance. That matches the reference
implementation, and it is worth knowing when somebody reports a client that
cannot delete while another one just did.
Uploads cost this server real processing work. Deletions cover both deleting a
post and undoing a boost, since either takes a post back out of other people's
timelines, and the general budget alone would let a script empty an account's
whole history in a couple of minutes.

Every API response carries `X-RateLimit-Limit`, `X-RateLimit-Remaining` and
`X-RateLimit-Reset`, the last as a timestamp. They describe whichever bucket
the caller is closest to exhausting, including across the two that an endpoint
with its own allowance charges, since that is the one they will hit. A
well-written client reads them and slows down on its own; one that ignores them
gets a `429` with the same headers.

Preflight requests are not counted. A browser sends one before most requests it
makes, and counting both would halve the budget of every web client.

## Forgotten passwords

Two limits, because one of them is not enough. The form at `/reset-password`
shares the sign-in limiter, twenty posts a minute per client address. That
stops one machine hammering it and does nothing at all about twenty machines
aimed at one mailbox, so there is a second limit of **three reset emails an
hour per account**, counted where the account is known.

That second count deliberately happens in a background job rather than in the
request. The page must answer identically whether or not the address has an
account here, and identically has to include how long it takes — a request that
sends mail on one branch and nothing on the other is measurably slower on one
branch. So every request queues one job and the job does everything that
differs.

Asking again retires the previous link rather than adding to it, so an account
never has more than one live reset link and the token table cannot be filled by
repeated asking.

## Signing up

Creating an account is bounded per address, whichever door it comes through:
**5 sign-ups per 30 minutes** from one address, counted the same whether
somebody used `/register` or an app used `POST /api/v1/accounts`. An app's
token does not buy it a budget of its own here — the address is what is
counted, because the whole point is that nobody is signed in yet.

The same address is what a [sign-up block](signup-blocks.md) matches on, and
both now see the browser form as well as the API.

## Action limits

How much of a thing one **account** may do, however they do it. These are not
about load; they are about the action being abusive in volume.

| Action | Allowance |
|---|---|
| Posting | 300 / 3 hours |
| Following | 400 / 24 hours |
| Reporting | 400 / 24 hours |

Three hundred posts in three hours is a spam run rather than a chatty
afternoon. Four hundred follows in a day is somebody building a follower list
by following everyone and unfollowing whoever does not follow back.

These count per account, so a person with six apps has one budget and moving to
a new address does not reset it.

## What this server does to other people's servers

One limit points outwards. Verifying a profile link means fetching the page it
points at, and everybody links to the same handful of sites, so a sweep across
your accounts would otherwise arrive at those sites as a burst. abuuba reads at
most **5 pages per minute from any one host**; a check the limit stops is
retried a minute later rather than dropped.

Links are re-read about once a week, and the sweep that queues the work runs
hourly and takes a bounded batch, so the load spreads across the day. Nothing
here is configurable yet.

## When somebody says they are blocked

Ask which they are seeing. A `429` with `X-RateLimit-Reset` is a request limit
and clears itself at the time in that header. A refusal when they try to post
or follow, with the rest of the app working normally, is an action limit and
clears after the window in the table above.

Neither is a moderation action, and neither leaves a record on the account. If
somebody hits one repeatedly during ordinary use, that is worth investigating
as a bug in their client rather than as a problem with the person.

## Behind a proxy

Anonymous limits are counted per client address, and that address is whatever
the socket reports. Behind a reverse proxy that is the proxy, so every
anonymous caller shares one bucket and the limit is reached almost immediately.

A deployment behind a proxy has to rewrite the client address from a header it
actually trusts. abuuba does not read `X-Forwarded-For` on its own, on purpose: a
client can set that header to anything, so trusting it unconditionally would
let anyone pick their own bucket and defeat the limits entirely.
