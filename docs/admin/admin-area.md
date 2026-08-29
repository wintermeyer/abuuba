# The admin area

`/admin`, one surface. Which sections it shows depends on what your role
holds, and moving between them does not cross a seam where the navigation and
the layout change.

## Getting in

Each section names the permission it needs:

| Section | Needs |
| --- | --- |
| Dashboard | `view_dashboard` |
| Accounts | `manage_users` |
| Reports | `manage_reports` |
| Custom emoji | `manage_custom_emojis` |
| Trends | `manage_taxonomies` |
| Announcements | `manage_announcements` |
| Sign-up blocks | `manage_blocks` |
| Server settings | `manage_settings` |
| Audit log | `view_audit_log` |

The navigation lists only what you may open, and typing the address of a
section you may not use is refused the same way. A link that answers "not
allowed" is a worse answer than no link.

The buttons on those screens are checked separately, and against the same
permissions. Being let into one section does not make another section's
buttons work, because what a screen sends is decided by whatever is at the
other end of the connection rather than by what was drawn on it.

Rank applies on top of permissions. `manage_users` says what kind of work you
do; position says who you may do it to, so an account holding a role above
yours shows no action form at all, and the event behind it is refused too.

## From a moderation client

Most of this area is reachable over the admin API, so a client can do the same
work: accounts (`/api/v1/admin/accounts`, and `/api/v2/admin/accounts` for a
newer client), reports, hashtags, the block families, and the dashboard's own
numbers.

The lists page the way the rest of the API does: `limit`, `max_id`, `since_id`
and `min_id`, with a `Link` header carrying the next page and nothing at all on
the last one. That matters most on the block families, which used to answer
with the whole table however large a shared blocklist had grown. The one
exception is `/api/v1/admin/trends/links/publishers`, which ranks publishers by
their most recent link and has no single id to page by; it takes `limit` only.

The numbers come in three shapes. `POST /api/v1/admin/measures` is one value
per day over a window; `POST /api/v1/admin/dimensions` is a breakdown, biggest
first; `/api/v1/admin/retention` is a cohort table. Two keys this server cannot
answer come back as an empty series rather than an error: `software_versions`
needs a version per peer, which nothing here asks for or stores, and
`space_usage` is a question only the storage layer can answer. A key nobody
defined is refused outright, so a typo in a client is not drawn as a quiet week.

`DELETE /api/v1/admin/accounts/:id` is the end of the grace window brought
forward: the account and its posts go, peers are told, and there is nothing to
appeal afterwards. It is not the same as a suspension.

## Dashboard

Three queue lengths (reports, appeals, people waiting to be let in) and a list
of **what needs attention**. The checks report only what is wrong: a page of
green ticks is read once and never again.

| Check | Fires when |
| --- | --- |
| `database` | The database did not answer |
| `instance_actor` | This server has no actor of its own, so servers running authorized fetch will refuse it |
| `registrations` | Anybody may sign up without approval |
| `administrator` | Nobody here holds the administrator permission |

## Appeals

Strikes that the person they were taken against says were a mistake. Uphold one
and the action is undone where it can be; turn it down and it stands. Either
way they are told. The full rules are in
[account actions](account-actions.md#appeals).

## Accounts

Search by handle (`name` or `name@server`), narrow by where the account lives
and what state it is in. From one account you can take any action on the
[moderation ladder](account-actions.md), lift one that can be lifted, give or
take away a role, and change an email address.

Changing an address is for the case where somebody cannot reach their own. It
is the only reason an admin should touch it.

People waiting to be let in have **Let in** and **Turn away** next to them, and
underneath, what they wrote when the sign-up form asked why they want to join.
That line is the only thing distinguishing one stranger from another, so read
it before deciding. It is absent for anybody who arrived on an invite, or who
signed up before the server started moderating registrations, because neither
was ever asked.

Turning somebody away deletes the account with the registration, or a rejected
sign-up holds its username against the next person who wants it and leaves a
profile nobody can sign in to.

## Trends

What is waiting to be reviewed and what is currently showing, with a decision
next to each. See [trends](trends.md) for how something gets there and why
nothing appears until somebody has allowed it.

## Announcements

Something everybody here should read, published now or at a time you give it.
See [announcements, rules, terms and invites](announcements-rules-terms-invites.md).

## Custom emoji

Pictures people here type into a post by name — `:blobcat:` renders as the
picture rather than the word.

Uploading one puts the file on this server's own storage, which is the whole
difference between offering an emoji and pointing at somebody else's: a copied
address stops answering the day that server goes away, and every post that used
the shortcode is left with a hole. PNG and GIF, at most 256 KB — a shortcode
renders at the size of a letter and is sent to everybody who reads a post using
it.

Three buttons, in order of how loud they are. **Stop offering it** takes one
out of the picker and out of `/api/v1/custom_emojis`; every post that already
carries the shortcode still renders, so this is what retiring a name usually
means. **Turn it off** stops the shortcode rendering at all, so those posts
show the bare `:name:` until somebody turns it back on — the row survives, and
turning it on restores all of them at once. **Remove** deletes it and its
picture, and those posts lose theirs for good.

Emoji this server has seen in other people's posts are listed too, under the
server they came from, and can only be removed. `:blobcat:` here and
`:blobcat:` there are two pictures with one name, and theirs is what their
posts render with — so uploading one of your own leaves theirs alone.

`mix abuuba.emoji` does the same from a shell, and can copy a whole set from
another server at once. See [Operational commands](mix-tasks.md).

## Sign-up blocks

Mail domains, email addresses, IP ranges and usernames this server refuses at
the door, plus the optional puzzle. See
[keeping abuse out at the door](signup-blocks.md).

## Server settings

Name, description, contact address, who may sign up and what to say when nobody
may, whether to talk only to the [allowlist](domain-blocks.md), and how long to
keep content from other servers.

There are two descriptions and they go to different places. **What this server
is for** is the short one, and it is what other servers and clients read from
the instance metadata. **The longer version, for the about page** is what
somebody reads on `/about` and what `/api/v1/instance/extended_description`
answers; leave it empty and that page carries only the name and the numbers. Below the form, the terms of service
with their versions, and the rules people agree to when they sign up and see
when they file a report. Retiring a rule keeps the row, so
an agreement recorded against it still means something.

Only the keys the form renders are written. A key arriving from anywhere else
is dropped rather than stored, because the settings table is read by the rest
of the server without asking where a value came from.

**Status page** is the address of wherever you say what is broken and when it
will be back — a hosted status page, a wiki page, anything with a URL. Clients
link to it from their server-information screen. It is refused rather than
stored if it is not an address, for the same reason the donation link is: a
typo here is a broken link on somebody else's screen, not yours.

**The account to write to** is a username on this server, and it is optional.
Clients show it beside the contact address on their server-information screen,
so somebody with a question has a person to ask rather than only a mailbox. A
name that belongs to nobody here is treated as none at all: a typo leaves the
line off a client's screen rather than breaking the endpoint every client
reads at startup.

**Privacy policy** is a text box and a date. What you write is the `/privacy`
page and what `/api/v1/instance/privacy_policy` answers, so a client showing
somebody what a server does with their data shows this. Leave it empty and
both say plainly that nothing has been written yet rather than showing a blank
page.

It is a setting rather than a versioned document, unlike the terms of service
below: the terms keep a row per version so that somebody can still read what
they agreed to on the day they agreed to it, and a privacy policy has no such
agreement attached to it.

**Who may read the public timelines** decides what a stranger sees. Open is
the default and what the rest of the fediverse assumes: the local and federated
timelines, the hashtag pages and the explore page answer anybody. *Only people
signed in here* keeps all of that for people with an account — a reader with no
token gets 422 from the API, and the pages here show nothing. *Nobody* turns
them off for everybody, including your own members, and the API answers 404
rather than 403: a server that has turned them off is saying there is nothing
here, not that you are unwelcome.

It does not hide anything else. A profile is still a profile, a post somebody
links to still opens, and this server still federates exactly as before —
posts go to the servers that follow them whatever this is set to. It is about
the lists this server puts on its own front door.

**Days to keep other servers' files** is enforced nightly.
`Abuuba.Media.VacuumWorker` runs at 03:45 and drops the cached bytes of any
remote attachment older than the cutoff; zero keeps them indefinitely. Only the
bytes go. The attachment row stays, so a post whose picture was swept still
reads as a post and fetches the picture again the next time somebody opens it.

**Days to keep other servers' posts** is the second retention, swept at 04:15,
half an hour after the first so two backlogs do not compete for the same disk.
Zero keeps them for ever, which is the default.

It refuses to delete a post somebody here did something with: favourited,
bookmarked, pinned, boosted, quoted, replied to, or was mentioned in. Upstream
deletes those too and lets the foreign keys take the bookmark with them; this
server does not, because a bookmark list that quietly loses entries loses them
without telling anybody. A mention is the same argument from the other side — a
notification whose post has gone is a notification about nothing.

Following somebody is not a reason to keep their posts. It cannot be: on the
server that needs a retention, the posts filling the disk are exactly the ones
its own people asked for.

At most 5,000 go per night, so a first run on a server that has never swept
clears over a few nights rather than in one long lock. The pictures are deleted
with them.

## Audit log

Who did what to whom, newest first, filterable by verb. The actor's handle and
the target's name are written into each entry rather than joined at read time,
because an entry is read when somebody asks what happened, which is most often
after the account it happened to was deleted. Two dangling integers cannot
answer that question, and the handle at the time is more truthful than a join
would be: somebody renamed since is not who the entry was written about.

Nothing here is edited or deleted. A log somebody can tidy is a log nobody can
rely on.

## Related

Uploads and transcoding are described in [the media pipeline](media.md).

## The API

`/api/v1/admin/*` for a moderation client, in Mastodon's shapes:

- `GET /accounts`, `GET /accounts/:id`, `POST /accounts/:id/action`,
  `/approve`, `/reject`, `/enable`, `/unsilence`, `/unsuspend`
- `GET /reports`, `GET /reports/:id`, `POST /reports/:id/resolve`, `/reopen`,
  `/assign_to_self`, `/unassign`
- `GET`/`POST` `/domain_blocks`, `GET`/`PUT`/`DELETE` `/domain_blocks/:id`
- `GET /trends/:kind`, `POST /trends/:kind/:subject/approve|reject`

Same permissions, same rank check, same context functions as the pages. Two
implementations of "suspend this account" is one implementation and one bug,
and the bug is always in the surface nobody is looking at.

The admin account entity carries the email address and role, which the public
account entity never does. `action` takes Mastodon's `sensitive` and applies
what the ladder calls `mark_statuses_as_sensitive`.

## The dashboard's charts

Below the counters: the last thirty days of the measures worth a chart — people
who posted, new accounts, posts written here, favourites and boosts and replies,
and reports opened and resolved — with where things come from beside them, and a
retention table underneath.

These are the same figures the admin API serves at `/api/v1/admin/measures`,
`/dimensions` and `/retention`, computed by the same code. A moderation client
drawing its own charts and this page should not be able to disagree about how
many posts were written yesterday.

Not every measure the API serves is on the page. A page of twenty charts is a
page nobody reads, so the dashboard shows the handful that answer "how is this
server doing" and leaves the rest to a client that has asked a narrower
question.

The charts are inline SVG with no library behind them. The shape of thirty
numbers is the whole question a dashboard chart answers, and pulling in a
charting library would mean a page that cannot be served under the same strict
policy as everything else here. Each carries its label and its highest value for
a reader who cannot see it.

**Retention** is, of the people who signed up in a given week, how many were
still posting in the weeks after. It means very little on a young server and
rather a lot on an old one; it is there so that the day it starts meaning
something, it is already being recorded.
