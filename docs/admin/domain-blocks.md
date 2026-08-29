# Blocking other servers

## Severity

| Severity | Means |
| --- | --- |
| `noop` | Nothing on its own. For a row that only rejects media or reports |
| `silence` | The domain drops out of everywhere nobody asked for it; people who chose to follow somebody there still do |
| `suspend` | Nothing accepted from it, nothing delivered to it, its accounts hidden here |

A block may also set `reject_media` (attachments from that domain are not
stored) and `reject_reports` (reports it forwards are dropped rather than
queued for a moderator to sift).

## Which block applies

A block on `bad.example` covers `users.bad.example`, or blocking a server would
be undone by whoever runs it pointing a subdomain at the same machine. Where
both a wide and a narrow block exist, the more specific one wins, so one part
of a server can be carved out of a decision about the rest.

Matching is on label boundaries. `notbad.example` is not a subdomain of
`bad.example` and never matches it, however similar the two strings look.

This server's own domain cannot be blocked. It would silence every local
account at once, which is one typo away from taking the server down from the
inside.

## What a block does when it is applied

Both severities reach the accounts already here. A silence sets them silenced
and leaves their follows alone. A suspension hides them, sets the same 30-day
purge window an account suspension uses, and **severs the follow relationships
in both directions**.

Severance is the part worth understanding before pressing the button. The
follows are deleted, not paused, and lifting the block later does not bring
them back: this end cannot recreate consent on the other one. What was lost is
recorded per local account, and everybody who lost something is told. A
follower count that drops overnight with no explanation is exactly the failure
that record exists to prevent.

## Changing one later

Raising the severity applies the harder decision. Lowering it lifts what the
harder one did, so a suspension dropped to a silence un-suspends the accounts
and leaves them silenced. Editing anything else, a comment or a flag, does not
re-apply the block and does not write a second severance event.

Lifting a block only lets an account back where nothing else still holds them:
a wider block on the parent domain, or an individual decision a moderator took
about that one account, both survive it.

## Comments and obfuscation

Whether `/api/v1/instance/domain_blocks` answers at all is **Who may read the
blocklist** in the server settings: nobody (the default -- the endpoint is a
404, which means "this server does not say"), only people signed in here, or
anybody. The list is a record of moderation decisions, and naming the servers
a moderator acted against is exactly what invites their users to come and
argue about it, so publishing it is a choice rather than a given. A stranger
under the signed-in setting gets the same 404 rather than a 401, which would
announce that something is being withheld.

When the list is served, `public_comment` is shown to whoever may read it.
`private_comment` is never published. Setting `obfuscate` publishes the domain
with everything but its last label replaced by asterisks, for the cases where
naming a server in full invites its users to come and argue about it.

A row whose severity is `noop` is left out of the public list entirely. It is a
decision about this server's own storage rather than a statement about that
server for the world to read.

## Carrying a list between servers

`Domains.export_csv/0` writes the column order shared blocklists use
(`#domain,#severity,#reject_media,#reject_reports,#public_comment,#obfuscate`)
and `Domains.import_csv/2` reads it back. A domain already blocked is skipped
rather than treated as an error, and so is a row that cannot be read: a shared
list is imported again every time it is updated, and refusing the whole file
over one duplicate is what makes somebody stop importing it.

## Allowlist mode

Setting `limited_federation` makes this server talk only to the domains on its
allowlist. Everything else is refused inbound and skipped outbound, without any
block existing for it, which is why allows are their own list: a domain that is
not on it has had no decision taken about it.

An allow is not an exemption from a block. A domain that is both allowed and
suspended is refused.

## Stopping delivery to one server

Separate from blocking, and separate again from the failure counting in
[when another server stops answering](federation-health.md). Stopping delivery
by hand is a decision, so an inbound request from that server does not clear it
the way it clears a domain this server gave up on after a week of failures.
Restarting delivery clears the failure count with it.

## What `reject_media` reaches

Both doors, so it holds for posts that arrived before the block as well as
after. A post coming in from that domain records no attachments at all, and
`Media.cache_remote/2` -- the one function that fetches somebody else's
picture, used by the media proxy and by `mix abuuba.media refresh` alike --
refuses for any attachment whose author is on such a domain. Nothing from that
server reaches this disk.

The match is on the **author's** domain, not on the file's address. Attachments
routinely sit on a separate CDN name, and a check against the file host would
miss most of them.

Files fetched before the block was written stay where they are; the retention
vacuum drops them on its own schedule, or `mix abuuba.media` clears them sooner.

## What is not wired up yet

Serving our own objects to a suspended domain over a plain GET is still
possible; refusing that needs authorized-fetch mode, which has its own issue.

## Lists as files

**Administration → Domain lists**, which needs `manage_federation`.

A server that has decided about four hundred domains has made four hundred
decisions, and the way those get shared is a list somebody publishes. Typing
them in one at a time is not something anybody does twice, and it is why a new
server's block list is usually empty for months.

Export gives you `#domain,#severity,#public_comment` for blocks and `#domain`
for allows — Mastodon's format, because the lists people publish are written by
Mastodon's exporter and the point of reading a file is reading the files that
exist.

**Importing adds and never removes.** A domain this server has already decided
about is left exactly as it is, and the answer says how many were added and how
many were already known. A file is somebody else's opinion arriving all at once;
applying it as a replacement would let one paste undo every decision you had
made, silently, with nothing in the file to undo it from.

A severity this server does not recognise is read as a silence. A file from
somebody else must not be able to delete accounts here because a column said a
word we have never seen.
