# Link previews

## What happens when somebody posts a link

The first link in a post is unfurled by a background job. Never inside the
request: unfurling means talking to a server that may be slow, down, or
deliberately taking its time, and posting would otherwise be as slow as the
slowest site anybody links to.

Only the first link. One card per post, and the first link is the one somebody
meant. Mentions and hashtags are links in the rendered markup and are never
unfurled, however much they look like one.

An edit is asked the same question again. The old card comes off the moment the
first link changes rather than when the new one arrives, because the fetch
talks to somebody else's server and may be slow, fail, or never happen at all
if the new text has no link in it — and a headline belonging to a URL that is
no longer in the post is worse than no headline, since a reader has no way to
tell it is stale. An edit that leaves the link alone leaves the card alone.

## oEmbed first, the page's own markup second

A site that publishes an oEmbed document has said how it wants to be embedded,
which beats anything we can infer. Where there is none, OpenGraph tags say most
of the same things; where there are none of those either, the `<title>` is
still more use to a reader than nothing at all.

**`rich` is refused.** oEmbed's rich type is arbitrary HTML with no shape
anybody can check, which is somebody else's markup running in our readers'
pages. The page's own tags are used instead.

A `video` embed is kept, but it is **rebuilt rather than cleaned**: the iframe's
`src` is taken, checked for https, and a minimal iframe is constructed around
it. A sanitiser answers "is there anything dangerous in this markup", which is
a question about everything somebody could write; constructing the element
ourselves answers "is this the shape we allow", which is a question about one
thing.

## The endpoint cache

Discovering a site's oEmbed endpoint costs a fetch and a parse of its HTML.
That is a property of the site rather than of the article, so it is cached per
host for 24 hours — and the second link from that host **skips the HTML fetch
entirely**, going straight to the endpoint.

"This host has none" is cached too. Without that half, every link to a site
without oEmbed pays for the discovery again on every post.

## One card per address

Cards are keyed on the address **after redirects**, so two shortened links to
one story are one card, and a story shared by two hundred people is one row
that every post points at. A card is re-read after two weeks: believed forever,
it becomes a headline that changed and a title nobody updated.

## Who wrote it

A `fediverse:creator` meta tag names an account. It is resolved against
accounts this server can actually see, and only a resolved one reaches the API
as an `authors` entry. A handle in somebody's markup is a claim; an account is
a fact, and showing an unverified one is the site claiming to be somebody.

## Safety

Every fetch goes through `Abuuba.Federation.HTTP`, which is where the address
checks, the redirect limit, the size cap and the per-host circuit breaker live.
A preview card is this server fetching a URL a stranger wrote, which is the
textbook shape of an SSRF, and nothing here reaches around that layer.

## Trends

A link counts towards [trending links](trends.md) when its card is attached to
a post, not when the card is fetched. A link nobody attached to a post is a
link nobody shared.
