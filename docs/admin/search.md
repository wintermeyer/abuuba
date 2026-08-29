# Search

## Postgres, not a search cluster

Full text lives in the database this server already runs. A search cluster is
another process to keep alive, another copy of the truth to keep in step, and
another way for the two to disagree. `Abuuba.Search` is a behaviour and
`Abuuba.Search.Postgres` implements it, so a server that outgrows this can point
`:search_adapter` at something else without a call site changing.

## `simple`, not a dictionary

A dictionary stems words in one language. A fediverse timeline is many at once,
and stemming German with English rules turns real words into ones nobody typed.
`simple` folds case and splits on punctuation and does nothing else, which is
right far more often than any single dictionary would be.

The consequence worth knowing: searching for `garden` does not find
`gardening`. Words are matched as words.

## What is indexed

| Table | Column | Contents |
| --- | --- | --- |
| `statuses` | `searchable` | Content warning and body |
| `accounts` | `searchable` | Display name (A), username (B), domain (C) |

Both are **generated columns**: Postgres keeps them in step with the text
itself. A trigger would be a second place the rule lives and the first place
for it to be forgotten by an `UPDATE` that skips it.

The content warning is searched with the body, because it is often the only
line a reader actually saw.

Accounts also carry trigram indexes on username and display name. Full text
cannot answer half a word, and half a word is exactly what an autocomplete
sends.

## Who can find a post

Stricter than who can read one:

- anything public or unlisted, by anybody;
- anything at all, by its author, anybody it mentions, and anybody who
  favourited, boosted or bookmarked it.

That last group is the "library", and it is implemented as **joins at query
time** rather than as a denormalised array on the row. The reference
implementation rewrites such an array on every favourite, which re-indexes a
popular post thousands of times; the same rule as a join costs a little more
per search and nothing per favourite, and searches are far rarer than
favourites.

`in:library` narrows to that group alone, `in:public` to what anybody may read.

## Operators

| Operator | Means |
| --- | --- |
| `from:alice` | One author. Naming nobody finds nothing |
| `has:media`, `has:poll` | Posts carrying something |
| `is:reply`, `is:sensitive`, `is:boost` | What kind of post |
| `language:de` | What it was written in |
| `in:library`, `in:public` | Where to look |
| `before:`, `after:`, `during:` | Dates, each meaning the whole day |

`is:` and `has:` may be repeated and each one narrows further; the rest keep
the last one typed, because two authors or two languages are a contradiction
rather than a refinement.

Anything that looks like an operator but is not one stays in the words, so
searching for `colour:blue` finds that text. A date that is not a date does the
same: `before:soon` is a search for "before:soon".

Quoted phrases and a leading minus work, because the words go to
`websearch_to_tsquery` rather than to a parser of our own. That also means
punctuation somebody typed never produces an error.

## Ranking

Posts come back newest first: a timeline is chronological and a search over one
should not invent an order nobody asked for.

Accounts are ranked by whether the reader already follows them, then by the
weighted text match, then by trigram closeness, then by follower count. The
person somebody means is nearly always somebody they already know.

Hashtags put an exact match first, then the closest, then the shortest.
