# Finding things

## Explore

`/explore` has three tabs, each its own address: **Posts**, **Hashtags** and
**People**. It works signed out, because a stranger deciding whether to join
should be able to see what is here first.

Everything on it is newest first. Ranking by what is actually getting attention
is a separate piece of work, and a "trending" label over an unranked list would
be a lie.

## The directory

The People tab lists local accounts that asked to be listed. The default is no:
somebody who never opened a settings page has not agreed to be on a public list
of who lives here.

## Suggestions

Apps that ask this server who you might follow get the accounts that the people
you already follow follow, ordered by how many of them agree. That is the one
signal built out of choices your own circle made, rather than out of what is
popular on the server.

Only accounts that asked to be findable appear, and never one you already
follow, have blocked, have muted, or have dismissed. Somebody who has blocked
you is out too, as is anybody on a server you have blocked and anybody you have
already asked to follow and are still waiting on. Dismissing is remembered, so
somebody you waved away does not come back on the next load. This web interface
has no suggestions column yet; the directory is the equivalent here.

## Collections

A collection is a list of accounts somebody put together and published:
"people I know who write about gardening", handed to a newcomer as one link
instead of twelve names typed out in a pinned post. It lives at
`/collections/<id>` and opens for somebody who has not signed up anywhere,
which is the point of it.

Anyone can make one from an app: give it a name, up to a hundred characters of
description, and optionally the hashtag it is about. Ten lists each, twenty-five
accounts each — a list of two hundred people recommends nothing.

**Being put on one does not need your permission, and taking yourself off does
not need anybody's.** You are told when it happens, and one press removes you
for good: whoever added you cannot put you back. If that sounds the wrong way
round, consider the alternative — a list whose twelve entries each need
answering before anybody sees anything is a list that never launches.

Under a post carrying a hashtag, an app may show the collections about that
hashtag. Only ones their owners left discoverable, and a list somebody keeps to
themselves is never counted as a fact about the people on it.

This web interface shows a collection's page. Making and editing one is
something apps do; there is no screen for it here yet.

## Hashtags

`/tags/gardening` shows everything filed under that tag. Case does not matter:
`#Gardening` and `#gardening` are one tag. A tag nobody has used yet is still a
page rather than a 404, because every hashtag in every post is a link to this
address.

Signed in, you can follow a tag, which puts its posts in your home timeline.

## Search

`/search` looks in three places at once: people, hashtags and posts. `?q=` and
`?type=` are in the address, so a search is a link you can send and a bookmark
you can keep.

You only see posts you are allowed to see. A followers-only post does not turn
up in a stranger's search because it matched a word.

### Narrowing a search

| Written | Finds |
| --- | --- |
| `from:alice` | posts by one person |
| `has:media` | posts carrying a picture, video or sound |
| `has:poll` | posts with a poll |
| `is:reply` | replies, or `is:boost`, or `is:sensitive` |
| `language:de` | posts written in one language |
| `in:library` | only what you wrote or kept |
| `in:public` | everything anybody may read |
| `before:2026-01-01` | posts older than a date |
| `after:2026-01-01` | posts newer than a date |
| `during:2026-01-01` | posts from one day |

They combine with words and with each other: `from:alice has:media gardening`.
`is:` and `has:` may be repeated and each one narrows further, so
`is:reply is:sensitive` finds replies that carry a warning rather than either
on its own. The rest keep the last one you typed, because two authors or two
languages are a contradiction rather than a refinement.
The `@` in front of a handle is optional.

Anything that looks like an operator but is not one stays part of the words, so
searching for `colour:blue` finds that text. A date that is not a date does the
same: `before:soon` is a search for "before:soon".

`from:` naming somebody who does not exist finds nothing rather than everything.
The operators narrow posts and mean nothing to a name or a tag, so those two
sections search the words you typed and ignore the operators.

## How the matching works

Search matches whole words, not fragments: looking for `garden` does not find
`gardening`. Put words in quotes to search for the phrase, and put a minus in
front of one to leave it out: `gardening -sun`.

Which posts you can find is narrower than which you can read. Anything public
is findable by anybody. Anything else is findable only by the person who wrote
it, anybody it mentions, and anybody who favourited, boosted or bookmarked it,
which is to say the people who kept it. `in:library` searches only what you
wrote or kept; `in:public` searches everything anybody may read.

## Trending

Explore lists what more people than usual are posting about right now: tags,
links and posts. It is worked out from how many different people used something
today compared with yesterday, so a tag ten people use every day does not show
up. Steady use is not a trend.

Nothing reaches those lists until somebody moderating this server has looked at
it and allowed it. That means the lists are shorter than they might be, and it
means what is on them is not simply whatever was pushed hardest.

Your own posts only ever appear there if your profile is set to be findable and
somebody moderating has allowed your account. Replies, posts marked sensitive,
and anything that is not public never count.

## The front page

Signed out, `/` says what this server is, whether you can sign up, and shows
recent public posts from people here. Signed in, it takes you straight to your
own timeline.
