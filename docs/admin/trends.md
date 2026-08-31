# Trends

## Nothing is shown before somebody has looked at it

A tag, a link or a post appears in the trending lists only once somebody
holding `manage_taxonomies` has allowed it. The trending list is the most
prominent place on a server, and handing it to whatever an anonymous crowd
pushed hardest is how it becomes a megaphone for the thing being pushed.

Three states, not two: allowed, refused, and nobody has looked yet. What the
third one does is the `trendable_by_default` setting's business, and it is off
out of the box.

The queue lives under **Administration → Trends** and at
`GET /api/v1/admin/trends/:kind?pending=true`. The people who can act on it are
told once per subject, not once per recompute: the ranking runs every five
minutes, and a notification each time would turn one busy tag into a hundred
and forty a day.

Links are decided per address or per site. A news site posting forty stories a
day is one judgement rather than forty. A post is decided by its author, since
reviewing every post one at a time is a queue nobody can keep up with, and the
judgement being made is about who wrote it.

## Counted in people, not in posts

The score is built from how many distinct accounts used something, not how many
times it was used. One person posting a tag two hundred times is one person
shouting, and a score built on uses would put them on the front page.

Counts live in Postgres: one row per subject per day with the numbers, plus one
narrow row per participating account that answers "have we already counted this
person today". No Redis, and no approximation that cannot be audited
afterwards. Rows older than yesterday are swept, so the tables stay the size of
what is happening now.

## The score

```
score = (observed - expected)² / expected
```

`expected` is yesterday's number of people, `observed` is today's. Something
used as much as it was yesterday scores zero however popular it is: a tag ten
people use every day is the server's furniture, not news. Squaring the
difference is what makes a jump from two to forty worth far more than a nudge
from two to four.

Scores then decay with a half-life that depends on what they are:

| Kind | Half-life |
| --- | --- |
| Post | 1 hour |
| Tag | 4 hours |
| Link | 8 hours |

A post is interesting for an hour, a tag for an afternoon, a link for most of a
working day. One half-life for all three would be wrong twice.

## What is eligible

A post contributes only if it is public, not a reply, not marked sensitive, and
its author asked to be discoverable and is neither silenced, suspended, nor
migrated to another account. That last list is the same one the public
directory and the follow suggestions use, so an account you take out of one is
out of all three.
Replies are left out deliberately: a conversation is not a trend, and counting
replies makes the loudest argument on the server the thing everybody is shown.

A post does not count itself, only the attention it gets. Otherwise every post
would start at one person and the newest would always be the trend.

## Ranking

Rewritten every five minutes by `Abuuba.Trends.RankWorker`, which then sweeps the
old counts. Rewritten rather than maintained: keeping a running rank correct
under concurrent writes is far harder than recomputing a few hundred rows, and
a rank five minutes stale is not a problem anybody has.

Rankings are kept apart by language, so a client asking for one language does
not get the others. A subject whose posts carry no language lands under "no
language in particular" rather than being dropped.

## The API

Public: `GET /api/v1/trends/tags`, `/trends/statuses`, `/trends/links`, each
taking `limit` and `language`.

Moderation: `GET /api/v1/admin/trends/:kind` (add `pending=true` for the queue)
and `POST /api/v1/admin/trends/:kind/:subject/approve|reject`, all behind
`manage_taxonomies`.

## Links and their cards

A link counts when its [preview card](preview-cards.md) is attached to a post,
which is also where the title and the picture in a trending entry come from.
Link detection reads bare hyperlinks out of post text and drops the fragment,
so one article shared with three different anchors is one link.
