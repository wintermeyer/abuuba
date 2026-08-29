# Taking over a Mastodon instance

## Read the report before you run anything

```
mix abuuba.import
```

That is a dry run and it is the default. It connects to the old instance's
database, checks everything that has to be true, counts what would come across,
and writes nothing at all. The alternative is finding out what an import does
by watching it do it, on a database somebody's server depends on.

```
mix abuuba.import --execute      # actually run it
mix abuuba.import --reset        # forget the checkpoints and start over
mix abuuba.import --verify       # check an import that has already run
```

## The domain cannot change

Every id, every URI and every signature the old server published names its
domain. `https://example.social/users/alice/statuses/123` is not a name that
can be rewritten: it is what every other server on the network has stored, what
every signature was made over, and what every link in every timeline points at.

A takeover onto a different domain is not a takeover. It is a fresh instance
holding somebody else's posts, and every reply from the rest of the network
still goes to the old host.

The check is made twice over. `MASTODON_LOCAL_DOMAIN` is compared with this
server's domain, and the source's own posts are read to see which domain they
were published under — because a mistyped variable would otherwise pass the
check that exists to catch exactly that. Host **and** port, since a development
server is `localhost:4000` and comparing hosts alone would call that a match
for every server on the machine.

## What it needs

| Variable | For |
| --- | --- |
| `MASTODON_DATABASE_URL` | the source database |
| `MASTODON_MEDIA_ROOT` | its files, if they are on disk |
| `MASTODON_S3_BUCKET` | or the bucket they are in |
| `MASTODON_LOCAL_DOMAIN` | what the old server called itself |

And the secrets the old server ran with:

```
SECRET_KEY_BASE
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
VAPID_PRIVATE_KEY
VAPID_PUBLIC_KEY
```

Rows come across with encrypted columns in them — two-factor secrets, for one —
and without the keys those columns are noise that looks like data.

## Which versions

The importer names the schema version it has been read against and refuses
anything newer. A column that moved between versions would be copied wrongly
and silently: the import finishes, and the damage shows up months later. An
older instance should run its own migrations first, which is something it can
do and this code cannot.

## Everything is checked at once

A run reports every problem it finds rather than the first, so an admin fixes
all of them in one go instead of discovering the next one each time they fix
the last. Each step adds its own preconditions to that list, so the dry run
also says whether the encryption keys in the environment actually decrypt the
data they are for. A key that is present but wrong is caught before anything is
written, not after. The one exception is the connection itself: everything else reads
that database, and five failures caused by one unreachable server would bury
the answer under its own consequences.

## It can be interrupted

Moving millions of rows will be interrupted — by a timeout, by a closed laptop,
by one bad row in the middle of a batch. Each step records the last source id
it wrote, and a second run continues from there rather than starting over.
That is also why every step has to be idempotent: a batch that was half written
when the connection dropped will be seen again.

`--reset` clears the marks, for the case where somebody means to start over
rather than continue.

## What comes across

Accounts, the people who own them, their signing keys and their OAuth
credentials are copied rather than translated. Ids stay the same, because the
old server's ids are already snowflakes and every URL it published contains
one. Password digests stay the same, so nobody has to reset anything. Client
ids and access tokens stay the same, so the app on somebody's phone keeps
working instead of signing itself out on the morning of the migration.

Along with them: roles and their permissions, profile fields and their
verification, suspensions and silences, moved accounts and the aliases that
made the move possible, two-factor secrets, and web push subscriptions with the
encryption each browser subscribed with.

Server-wide configuration comes too, including the webhooks an admin has set
up: both projects spell the seven event names identically, so a chat room or a
moderation tool carries on being told about this server without anybody
re-entering an endpoint. The one thing left behind is the source's payload
`template`, which abuuba has no counterpart for.

Also carried: collections and who is in them, in the order their author put
them in and including anybody who had taken themselves back out; email
subscriptions, with the token a pending confirmation link already points at, so
nobody is asked to decide twice; and the severance records that explain which
domain block took somebody's follows away.

### Keys, and why exactly one

Older instances keep an account's key in two columns on the account. Newer ones
keep a table of them and publish whichever they sign with. abuuba publishes one
key per actor, and the one it takes is the one the old server was signing with,
so the public half other servers fetch after the switch is the half they were
already trusting.

Any other key an account had is kept, so nothing is lost, but marked as no
longer in use. A live key that nothing on the network can resolve is worse than
a row that says so plainly.

Private keys and two-factor secrets are the two things read rather than copied:
they sit in columns Rails encrypted, so they are decrypted with the old
server's keys and encrypted again with ours. The import stops before writing
anything at all if those keys turn out not to work. Copying the ciphertext
across instead would finish, look fine, and leave every account unable to sign.

### Posts, media and the graph

Statuses keep their ids and their URIs, so every permalink on the fediverse
still resolves and every server that stored one still matches it. Along with
them: threads and boosts, edits, mentions, tags, polls and their votes,
favourites, bookmarks, pins, conversations, preview cards, quotes, and the
counters the source had already worked out.

The follow graph is the part nobody can rebuild — the only two records of a
follow are the two servers holding it, and one of them is being replaced — so
follows come across with the URIs a peer's later unfollow will name, and with
whether boosts are shown, whether posts notify, and which languages were asked
for. Blocks, mutes, domain blocks, lists, filters, read markers, scheduled
posts, notification policies and private notes come with them.

Instance-level: settings abuuba understands, rules, terms, custom emojis, domain
blocks and allows, signup blocks, invites, announcements, relays, and the whole
moderation history — reports, strikes, appeals and notes, keeping the moderator
and the report each one came from.

**Deleted posts are not copied**, and that turns every reference to a status
into a question. A reply whose parent was deleted keeps the reply and loses the
thread; an attachment on a deleted post keeps the file and forgets the post; a
favourite of one is not copied at all. Each query asks the source the same
question the statuses step asked, so nothing is written pointing at a row that
is not there.

### Media files

The file tree is copied rather than the files being re-uploaded, because abuuba
lays media out exactly the way Mastodon does: `media_attachments/files/`, split
into three-digit groups by id, then the style, then the file name. A row that
named a file over there names the same file here.

Cached copies of other servers' media are skipped — that is what the `cache/`
prefix marks, it is usually the larger half of the disk, and the first sweep
would delete it anyway. The source tree is left untouched, and a file already
at the destination with the same size is not copied again, so an interrupted
copy continues rather than starting over.

Older attachments carry a storage schema version, which on the source decides
only whether *cached* files sit under `cache/`. Local files are laid out the
same way in every version, so nothing needs translating.

### Rebuilt afterwards

Home timelines. The source keeps them in Redis, which a takeover does not read,
and they are cheap to rebuild from the follow graph that has just landed —
without it everybody signs in to an empty timeline and concludes the migration
lost their posts. Counters came across with the rows they count, and the search
index is a generated column that Postgres filled in as the rows were written.

### Disabled accounts stay disabled

An account a moderator disabled on the old server is disabled here, in the same
representation abuuba's own **Disable** action uses. Distinct from suspension:
the posts stay exactly where they are, and only the door is closed. Dropping
the state would hand those accounts back on the day of the takeover, quietly.

## Verifying afterwards

```
mix abuuba.import --verify
```

Run it while the old database is still reachable, because it works by comparing
against it. Two questions:

- **Do the keys still sign?** Each imported key signs a real request, and the
  signature is checked against the public half the old server published. If
  this fails, every server on the network rejects everything this one sends.
- **Would the URLs still be the same?** The actor URL and webfinger name this
  server would publish for each local account, against the ones the old server
  did. The difference between them is the set of links on the fediverse that
  would stop resolving.
- **Did every post arrive?** The number of statuses here against the number
  there, counting deleted ones on neither side.
- **Do the follower digests match?** Peers keep an XOR-SHA256 digest of the
  followers they believe this server has for each account and compare it with
  the one this server publishes. It is computed here from the source's rows and
  from ours, per account and per peer domain: a pair that differs is followers
  the import did not carry across whole, and that peer will say so the next
  time it asks.
- **Are the files really there?** A sample of attachments, asked through the
  storage layer at the key the row produces — the same question a browser asks.
- **Does anybody have an empty home timeline?** Only accounts that follow
  somebody; an account following nobody has an empty feed and that is correct.

It exits with an error if either check finds something, so it can go in a
script. Neither finding is a warning. Every step contributes its own checks, so
this grows as the import does rather than staying whatever the first step
happened to look at.

## What is deliberately not copied

| Skipped | Why |
| --- | --- |
| Deleted posts | Already gone on the source |
| Remote media | A cache; it is fetched again from the servers it came from |
| Sessions | Everybody signs in again; a copied session is a copied cookie |
| Sidekiq and Redis state | Queues and caches, not data |
| Confirmation and reset tokens | Short-lived, and reissued on demand |
| Expired tokens and codes | abuuba's tokens do not expire, so copying an expired one would revive a credential the old server had already stopped honouring |

The report lists these rather than quietly subtracting them, because a number
that does not add up is what makes somebody distrust the whole thing.

## Not carried across yet

Different from the table above: these are not decisions, they are gaps. abuuba
has the feature and the importer does not yet read the source's table, so the
data stays behind on a takeover. Listed because an admin planning a migration
needs to know before running it, not afterwards.

| Left behind | What that costs |
| --- | --- |
| Login activity | The recent sign-ins list starts empty. abuuba records new ones from the first sign-in and does not show them anywhere yet |
| WebAuthn credentials | Nothing here reads them yet, so a copy would sit unused; anybody using a security key sets it up again when abuuba surfaces them |

The list was built by comparing the source's tables against the ones here, so
it catches a feature abuuba stores under the same name. Somewhere the two
projects model the same thing differently, a gap could hide from that
comparison; if something you rely on is missing after a run, say so rather than
assuming it was deliberate.

## What this does not do yet

Archives (`.zip` exports), CSV imports and Move-based migration from another
server arrive with their own issues. This is the database takeover: one
Mastodon instance becoming this one, on the same domain.
