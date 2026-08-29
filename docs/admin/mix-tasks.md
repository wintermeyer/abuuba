# Operational commands

Everything below is `mix abuuba.<group> <command>`, and every one of them needs a
checkout with Mix in it.

**They do not run on a release.** A release ships without the `mix`
application, so a task's first line — which starts the application through
`Mix.Task.run/1` — raises `Mix.Task is not available` before it does anything.
The task modules are in the release, which makes this look worth trying; it is
not.

What a release does have is `bin/abuuba eval`, which calls plain functions:

```sh
bin/abuuba eval 'Abuuba.Release.migrate()'
bin/abuuba eval 'Abuuba.Release.rollback(Abuuba.Repo, 20260101120000)'
bin/abuuba eval 'Abuuba.Release.bootstrap_owner(%{username: "alice", email: "alice@example.com"})'
```

Any public context function works the same way, so a one-off can be done by
hand:

```sh
bin/abuuba eval 'Abuuba.Settings.put_registration_mode("closed")'
```

What you lose doing that is the dry run, the progress and the argument
checking, which is most of why these tasks exist. For anything routine, run
them from a checkout pointed at the production database rather than from the
release.

## Every destructive command takes `--dry-run`

That is not a convenience. These run on a live server, at the keyboard, usually
by somebody already having a bad morning, and the difference between "delete
media older than 30 days" and "…than 3 days" is one keystroke.

The count a dry run prints comes from the same query the deletion uses. A dry
run that counted differently from the real one would be worse than none: it
would be a number somebody trusted.

Long commands write their progress on one line, and print a total at the end
whether or not anything happened — "0 removed" is an answer and silence is not.

## Accounts

```
mix abuuba.accounts bootstrap-owner alice --email alice@example.com  # the first admin
mix abuuba.accounts create alice --email alice@example.com
mix abuuba.accounts modify alice --email new@example.com --role Moderator
mix abuuba.accounts modify alice --disable # stop the sign-in, keep the account
mix abuuba.accounts merge old@far.example new@far.example
mix abuuba.accounts duplicates              # remote accounts sharing a signing key
mix abuuba.accounts rotate-keys alice      # or --all
mix abuuba.accounts backup alice           # build the archive its owner would ask for
mix abuuba.accounts approve --all          # let the waiting registrations in
mix abuuba.accounts approve alice
mix abuuba.accounts delete alice           # close it the way its owner would
mix abuuba.accounts refresh                # ask other servers for their accounts again
mix abuuba.accounts refresh --domain remote.example
mix abuuba.accounts cull --dry-run         # remote accounts on dead servers nobody follows
mix abuuba.accounts unfollow spam@spam.example
mix abuuba.accounts self-destruct --confirm abuuba.example  # shut the server down
```

`self-destruct` closes every account here and tells every peer that has heard
of them to forget them, for shutting an instance down properly rather than
turning it off and leaving its people as ghosts on a hundred other servers. It
wants the server's own domain typed out rather than a yes/no prompt, because an
operator who has to name the thing they are destroying cannot do it by pressing
return in the wrong terminal. There is no undo.

`duplicates` reports remote accounts that sign with the same key, which is what
says two rows are one person, and prints the `merge` that would join each pair
rather than running it. Which of the two survives is a judgement about the
handle people already know. Nothing is reported on a healthy server: duplicates
come from a peer changing its actor URI, or from one actor being fetched twice
under two identities.

`create` skips the two gates the sign-up form enforces — whether the server is
open, and the sign-up block lists. Both answer "may this stranger make an
account here", and somebody at a shell on this server is not that stranger. The
account is confirmed and approved on the way in, and the password is generated
and printed once: the column holds a hash, so an admin who loses that line
sends a reset rather than looking it up.

`merge` is for two rows that are one person on another server — a rename or a
domain move this server heard as a new actor, leaving their posts, follows and
blocks split across two accounts. Everything naming the first is repointed at
the second and the first is deleted, in one transaction. What counts as "the
same person" is the signing key: nobody else can sign as them. `--force`
overrides that for the case it cannot recognise, a server that rotated its key
between the two fetches; forcing for any other reason asserts that two
strangers are one person, and every post one wrote becomes the other's.

It refuses local accounts. Merging two accounts here is a decision for the
person they belong to — their usernames are promises this server made and their
posts have addresses other servers stored — and the way to do it is to move one
account to the other from the settings.

The references it moves come from the database's own catalogue rather than a
list in the code, so a table added later is covered without anybody remembering
this command exists. Where a row would collide — somebody who followed both
accounts, which is what having two of them allowed — the duplicate's row is
dropped and the survivor's kept.

`rotate-keys` gives an account a new signing keypair and revokes the old one
without deleting it — a post signed with the old key is still out there, and a
peer checking that signature needs the key. Every server this account federates
with picks up the new key the next time it re-fetches the profile.

`backup` asks for the same archive the export page builds, through the same
job, and it lands under **Settings → Export** for its owner. One way of making
an archive, and it is the way that has been tested.

`delete` goes through the ordinary closure: the username is kept and can never
be handed to anybody else, peers are told, and the rows go with the purge.

`cull` needs both conditions — unreachable **and** unfollowed. Either alone is a
live account: a server that is down comes back, and somebody nobody here follows
may still be in a thread people are reading.

`unfollow` is for a spam account whose server is gone and which therefore cannot
be asked to stop.

## Media

```
mix abuuba.media usage                     # what is on the disk, and in what
mix abuuba.media refresh --days 30         # pull back cached copies whose file has gone
mix abuuba.media remove-orphaned --dry-run # attachment rows whose post is gone
mix abuuba.media remove-remote --days 30   # cached copies of other people's media
```

`usage` is nearly always the answer to "why is the disk full", and nearly always
the second number.

`remove-orphaned` leaves anything under a day old alone: an attachment with no
post yet is the ordinary state of one being uploaded right now, and deleting
those would delete the picture somebody is in the middle of posting.

It also runs nightly on its own at 04:45, so the command is for when you would
rather not wait for that. It used to be the only thing that reclaimed an
orphan, which meant a server whose admin never typed it kept every abandoned
upload for good.

`remove-remote` deletes a cache. What goes still exists where it came from, and
a reader who opens an old post fetches it again.

## Feeds

```
mix abuuba.feeds build                     # rebuild every home timeline
mix abuuba.feeds build alice
mix abuuba.feeds clear
```

For after an import, a restore, or anything that left somebody looking at an
empty timeline they should not be. `clear` is separate on purpose, so that
"empty everybody's timeline" is never something a rebuild does by accident on a
server where the rebuild then fails.

## Domains

```
mix abuuba.domains list                    # who is actually on the other end
mix abuuba.domains purge spam.example --dry-run
```

`purge` is the most destructive command here: every account from that server and
everything hanging off them. For a domain that is gone, or one that was blocked
and whose rows are still taking up room and turning up in search.

## Posts

```
mix abuuba.statuses usage                  # how many, and what the table costs
mix abuuba.statuses usage --days 90        # …and how many a prune would take
mix abuuba.statuses remove --days 90 --dry-run
mix abuuba.statuses remove --days 90
```

Nothing removes a post from another server, so `statuses` only grows. On a
server that has federated for a year it is the largest table and the largest
set of indexes on the machine. `mix abuuba.media remove-remote` frees the images;
this frees the rows and their text, which is most of what remains.

Posts written here are never touched, whatever their age. They are this
server's own record and other servers hold their addresses.

A post from elsewhere stays, however old, when anything here points at it:
somebody favourited, bookmarked, boosted, replied to, quoted, pinned, filtered,
voted in or reported it, it mentions somebody here, a notification points at
it, it is still in a timeline here, or it is an ancestor of a post that stays.
That last one is why a thread is never cut off halfway: keeping a reply and
deleting its parent leaves a conversation that cannot be read from the top, and
the break would be silent.

Direct and limited posts are never removed by age at all. One of those was
addressed to particular people rather than published, there are few enough of
them that keeping all of them costs nothing, and removing one by mistake takes
away somebody's correspondence.

`--days` is required and has no default. A cutoff is a judgement about how far
back this server's readers ever look, and that is not one to inherit from
whoever wrote the command.

Working out what is safe to remove is one recursive walk over every post on the
server, so on a large one both `usage --days` and `remove` take minutes rather
than seconds. Run them where a dropped connection will not take the command
with it.

It does not hand disk back to the filesystem. Postgres marks the rows dead and
reuses the space for new ones, which is what you want on a server that keeps
receiving posts. After a large one-off prune, `VACUUM FULL statuses` gives the
space back, at the cost of an exclusive lock and room for a second copy of the
table.

## Preview cards

```
mix abuuba.cards usage                     # how many, and which sites they came from
mix abuuba.cards remove --domain sold.example --dry-run
mix abuuba.cards remove --days 365
```

A card is a copy of what a page said when it was fetched, so a site that has
since become something else keeps advertising its old self here until the card
goes. Removing one leaves the post and its link alone; the next reader who
opens it fetches the page again.

`remove` insists on `--domain` or `--days`. With neither it would mean "every
preview card on the server", which is not something to do by pressing return in
the wrong terminal.

## Custom emoji

```
mix abuuba.emoji list                      # ours, then a count per server
mix abuuba.emoji import --from mastodon.social --prefix soc_
mix abuuba.emoji purge --domain gone.example --dry-run
```

Emoji rows are addresses rather than pictures: the image is served from where
it lives, so purging removes this server's note of it and nothing else, and
importing copies the address rather than the file.

`import` skips a shortcode already taken here rather than overwriting it —
`:blobcat:` here and `:blobcat:` there are two different pictures with the same
name, and swapping one for the other changes what every post that used it looks
like. `--prefix` is how you take both.

## Search

```
mix abuuba.search usage                    # what each index costs, and how used
mix abuuba.search reindex
```

There is nothing to re-extract. The searchable text is a generated column, so
Postgres computes it as each row is written and it cannot drift — which is the
opposite of the Mastodon habit this command name comes from. Reindexing is for
the two cases where a Postgres index itself is suspect: corruption, and a major
version upgrade or collation change.

It rebuilds concurrently, so writes keep working, and it reports any index left
invalid by a failed rebuild. That matters because an invalid index is not an
error on the next query — it is simply not used, so search gets slower and
nothing says why.

## Counter caches

```
mix abuuba.stats drift                     # how many counters disagree
mix abuuba.stats recount                   # put them right
mix abuuba.stats recount --dry-run
```

Follower counts, post counts, favourite counts and the rest are a cache. The
rows in `follows`, `statuses`, `favourites` and `quotes` are the truth. They are
kept in step by single statements Postgres evaluates, so they do not drift on
their own; they drift when something died between writing a row and counting
it, or when a restore brought one table back further than another.

`drift` answers without writing, so you can find out whether anything is wrong
before touching a production table. `recount` fixes it in two statements rather
than a row at a time, so a million accounts is not a million queries.

Run it when the server is quiet, or run it twice. A favourite that lands
between the count being read and the counter being written is counted by its
own increment and then overwritten, so a recount under load can leave one
behind; a second run finds it.

It leaves `last_status_at` alone. An imported post moves the counters and
deliberately does not move that, because an archive is old news and stamping it
would put a decade-old post forward as the latest thing somebody said.

## Migrations

```
mix abuuba.migrations
```

Creates an empty database, applies every migration in order, rolls every one of
them back, and drops it again. Nothing else on the machine is touched: the
scratch database is the configured one with `_migration_check` on the end, and
it goes at both ends of the run.

Worth running before a release, and after writing a migration. A deployment
applies migrations to a database that already has the previous ones, and the
test suite only ever moves its database forward, so the chain from nothing and
the way back are the two things nothing else exercises.

The way back is the one that matters. [Deploying](../deploy.md) tells you to
reach for `Abuuba.Release.rollback/2` when a deploy has gone wrong, and that is a
poor moment to find out a migration has no working `down`. Nothing warns you at
compile time: a `change/0` Ecto cannot reverse, or an `execute/1` with no second
argument, fails when it is run and not before.

## Not here yet

`tootctl` has more than this. Missing so far: the domain crawl, and importing
custom emoji from a tarball. The tarball import needs somewhere to put the
images, so it wants a feature rather than a command.
