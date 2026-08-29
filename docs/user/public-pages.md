# Public pages, embeds and sharing

## What a visitor sees

Posts, profiles, explore, tags, the front page and the about page all work
without signing in and without JavaScript. They are built by the server, so a
link you paste anywhere shows a real preview and somebody following it reads
the actual page rather than a loading spinner.

## Search engines

Every public page here asks search engines to stay away, and keeps asking until
the account it belongs to says otherwise. **Let search engines index my posts**
under Settings → Privacy is the switch, it starts off, and turning it on lifts
the request from your profile and from your posts. The follower and following
pages never lift it, because they are a list of other people who did not get
asked.

The pages that gather other people's posts — explore, a hashtag, a search
result, a collection — ask them to stay away whatever anybody has ticked. The
authors on one of those pages disagree with each other, and the safe reading of
a disagreement is the stricter one. `/about`, the front page, the terms and the
privacy page stay findable: those are the server's own words, and an instance
nobody can search for is no use to the person looking for one.

This is a request rather than a wall. A crawler that ignores it is not stopped
by anything on this page, and a post somebody else quoted or boosted lives on
their server under their setting.

## About, terms and privacy

`/about` carries what this server is, its rules, how to reach whoever runs it,
and the numbers: people, posts, servers known, and how many people have been
active this month and this half-year. They are the same numbers the API
reports, so the two cannot disagree.

`/terms` and `/privacy` show what the admin here wrote, with the date the text
took effect. Terms somebody agreed to in March are not the terms that appeared
in September, so the date is part of the document. When nothing has been
written the page says so instead of being blank.

## Embedding a post

Every public post can be put on another page. `/embed/<id>` is the post on its
own, with no navigation and no compose box, and it is the only address on this
server that may be framed.

Editors that understand oEmbed find it by themselves: a post's page carries a
`json+oembed` link, and `/api/oembed?url=<the post>` describes the frame. Only
addresses on this server are answered, so this endpoint cannot be used to make
somebody else's page look like it came from here.

An embed shows only what everybody can see. A followers-only post has no embed.

## Sharing to here

`/share?title=…&text=…&url=…` opens the compose box with those pieces in it,
which is what a "share to your fediverse server" button on another site points
at. Nothing is posted until you press send.

## Acting from your own server

If you are reading a post here and your account is somewhere else, following,
replying and boosting all happen on your server rather than this one.
`/authorize_interaction?uri=<the post>` asks for your handle and sends you to
your own server's search with that address filled in.

No password is asked for and nothing is done on your behalf. All that happens
is a redirect.

## Who follows whom

`/@name/followers` and `/@name/following`, linked as tabs on every profile.
They are public, because who somebody follows is public on the profile they
follow from.

Anybody who would rather they were not can turn **Hide who I follow and who
follows me** on under Settings → Privacy. The pages then say so to everybody
except the account's owner, who still sees their own — a setting that hid the
lists from the person who set it would look like a bug the first time they
checked it worked. Apps reading the API get the same empty answer, so the
setting means the same thing wherever somebody looks. The follows themselves
keep working either way.

The featured accounts strip on the profile goes with them, since everybody in
it is somebody the account follows.

## Feeds

`/@name/feed.rss` is one person's public posts, and `/tags/something/feed.rss`
is everything public on one hashtag. Both are ordinary RSS, so any feed reader
takes them, and neither needs an account anywhere.

The hashtag feed follows the same rule as the hashtag page: on a server whose
admin has closed the timelines to people without an account, it comes back
empty. A profile feed is not a timeline and is unaffected.

What is in a feed is public posts only, and never a boost: a feed is a list of
things somebody wrote, and one that filled up with other people's posts after a
busy afternoon of boosting is a feed people unsubscribe from. Unlisted posts
are out too, because unlisted means "not in the lists this server publishes"
and a feed is one of those lists.

A content warning becomes the item's title, so a reader's list view carries the
warning rather than the thing it was warning about.

## Two addresses for the same thing

Every account and every post here has two addresses. `/@alice` and
`/@alice/12345` are the pages people read. `/users/alice` and
`/users/alice/statuses/12345` are what other servers use: those are the ids
that travel inside every message abuuba sends, so they turn up in other people's
databases and, sooner or later, pasted into a browser or a chat window.

Opening one of those in a browser sends you to the page. The address itself is
unchanged for other servers — they ask for a different format and get the same
answer they always did — so a link somebody copied out of a message still works
for a person without breaking anything for a machine.

Addresses that have no page, like a profile's outbox, still say they cannot be
shown as one. Sending you to the profile instead would be answering a question
you did not ask.
