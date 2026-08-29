# Feeds

## What the table is

`feed_entries` holds one row per post per feed it belongs in:

```
feed_type   home or list
feed_id     the account id, or the list id
status_id   the post
```

Three columns and no more. The status id is a snowflake, so it is the
timestamp, the sort key and the pagination cursor at once; a `created_at`
column would store the same information twice in the table that grows fastest.

The primary key is `(feed_type, feed_id, status_id)`, which is the shape of
every read: one feed, newest first, seek by cursor. It doubles as the
uniqueness that makes a fan-out job running twice harmless.

## Why the answer is written, not asked

A home timeline is "everything by everybody I follow, minus what I filtered
out". Asking that at read time means joining the follow graph on every scroll,
for every reader, forever. Writing it once when a post is made turns every read
into an index scan over one account's rows.

## What the fan-out does

When a post is made:

1. The author's own feed is written first, inline, before any job exists. A
   post that takes a second to appear in your own timeline reads as one that
   failed.
2. The audience is the author's active followers. Active means signed in within
   the last seven days; a feed written for somebody who has not opened the
   place in months is rows nobody reads, paid for on every post.
3. That list is cut into chunks of 500. The first chunk is written now, the
   rest go to the queue, so posting does not take as long as the audience is
   large and a post to three people does not wait on a job runner.
4. Each chunk loads its filter data once for all 500 people and finishes with
   one bulk insert.

The last point is the design. One job per follower means twenty thousand jobs
each loading one person's blocks and mutes; this is forty jobs and a handful of
queries each.

## What is filtered, and when

Decided at **write** time, because they are facts about who wanted the post:

- blocks in both directions, and domain blocks
- mutes that were already in place
- an exclusive list the author is in
- a muted thread
- `show_reblogs` and the per-follow language filter
- reply visibility: a reply reaches somebody only if they also follow the
  person being replied to, or it is a self-reply, or they are the one being
  replied to

Decided at **read** time, because they are reversible and can arrive after the
post did:

- blocks, mutes and thread mutes as they stand now
- the post's visibility as it stands now

Blocking and unfollowing also clear what that person already put in the feed.
Without that, somebody who just blocked a person keeps reading them until the
cap pushes them out.

## Relationship changes rewrite feeds

A feed is a cached answer, so anything that changes the question has to change
the answer.

| What happened | What the feed does |
| --- | --- |
| Follow | Their recent posts are brought in, filtered as the fan-out would have filtered them |
| Unfollow | Their posts go, unless a followed hashtag still reaches them |
| Block | Their posts, boosts **of** them, and posts that merely mention them all go |
| Mute | The same as a block |
| Unmute | Their posts come back |
| Follow a hashtag | Its recent public posts are brought in |
| Unfollow a hashtag | Its posts go, unless a follow still reaches them |
| Add to a list | Their recent posts are brought into that list's feed |
| Remove from a list | Their posts leave that list's feed |

Two rules are worth stating outright.

**A post belongs in a feed for as many reasons as the reader has.** Removing
one reason must not remove the post if another still holds, which is why
unfollowing somebody leaves a post that arrived through a followed hashtag, and
unfollowing a hashtag leaves a post by somebody still followed.

**A block outranks every reason.** There is no reachability check on a block or
a mute: a friend's boost of the blocked person is still that person's words,
and a post that only mentions them still carries their handle into the
timeline. Unfollowing is deliberately gentler, because it says "I do not
subscribe to you" rather than "I do not want to see you".

Unmuting brings the posts back; unblocking does not, because a block tears down
the follow and there is nothing to bring back until somebody follows again.

## Feeds that are empty but should not be

Somebody who has been away long enough for their feed to be trimmed to nothing
would otherwise be told there is nothing to read. `GET
/api/v1/timelines/home` answers **206** with `x-feed-regenerating: true`
instead of an empty 200, and queues a rebuild. A client should try again
shortly rather than showing an empty column.

An empty feed that is empty on purpose is a plain 200: somebody following
nobody, or somebody who has put everybody they follow into an exclusive list,
is not waiting for anything.

## The same post, boosted five times

Five people boosting one post inside somebody's visible window is one thing
that happened, not five, and a timeline that shows it five times is a timeline
people scroll past.

The first arrival is shown. Every later boost of the same original is stored
with `hidden_by_status_id` pointing at whatever is standing in for it, and
every read leaves those rows out. The original itself counts as standing in for
it: somebody who follows both the author and a booster has already read it, and
a copy underneath is a copy.

They are stored rather than dropped because the one on show can go away. Its
booster can take the boost back, the post can be deleted, or the author can be
unfollowed. When the shown entry leaves, one hidden entry is brought forward —
one, not all, because the reason for hiding them holds just as well afterwards.
Whatever was behind the departing entry is re-pointed at the promoted one, so a
second departure promotes the next in line.

Every removal path goes through the same promotion. An entry left hidden behind
something that is no longer there is a post that silently never appears again,
and that is the failure mode worth guarding.

## The cap

A feed keeps its newest 800 entries. The cap is enforced by a sweeper every
fifteen minutes rather than on every insert: trimming on write turns one insert
into an insert and a delete on the hottest path there is, and a feed sitting a
few hundred rows over its cap for a minute costs nobody anything.

## What the maintenance sweeper does

`Abuuba.Timelines.MaintenanceWorker` runs every fifteen minutes and does three
things, each a batch at a time:

1. **Trims** feeds over the cap.
2. **Empties** the home feed of anybody who has not signed in for 180 days.
   It costs them nothing: the first request after they come back answers 206
   and queues a rebuild.
3. **Clears orphans** — feeds whose account no longer exists.

`feed_entries` names an account by id with no foreign key behind it, on
purpose: a key would put a lock on `accounts` in the path of every fan-out
insert, which is the last place to spend one. Deleting an account clears its
feed directly rather than leaving it for the sweeper, and the sweeper catches
whatever any other path leaves behind.

## Pushing to whoever is watching

`Abuuba.Timelines.Broadcast` sits between the feed and every open socket.

**Rendered once.** A post reaching ten thousand sockets is one post, and most
of a rendered status is the same for everybody: the words, the author, the
attachments, the counts. That half is built once and kept in ETS for five
seconds; each socket patches its own reader's four booleans on top. The cache
is a burst buffer for the pushes that follow one post, not a second copy of the
database, and an edit or a deletion clears the entry rather than waiting it out.

**Nothing rendered for an empty room.** Most topics have nobody on them most of
the time: a hashtag nobody is streaming, a public timeline on a quiet server,
an account whose owner is asleep. Subscriptions are counted, and a publish to a
topic with no listeners returns without touching the database. The count is
kept here because `Phoenix.PubSub` does not offer one, and a subscriber that
dies without unsubscribing is noticed by its monitor rather than leaving a
count that never comes down.

**One layer, two consumers.** The LiveView interface and the Mastodon streaming
socket read the same broadcasts through the same renderer. Two paths would mean
two answers to "has this person favourited it", and the one nobody is looking
at would be the wrong one.

## Operating notes

- The table grows with posts times followers. It is the largest table on a busy
  server and the one to watch.
- The fan-out runs in the `ingress` queue. Backlog there means new posts are
  reaching some followers late; the author and the first 500 are unaffected.
- A post deleted between being written and its job running is not an error. The
  job finds nothing and stops.
