# Keeping abuse out at the door

**Administration → Sign-up blocks**, behind `manage_blocks`. Four lists and a
puzzle, and most of them have a middle setting.

## Three answers, not two

A check answers "yes", "no", or "a person looks at this one". The middle answer
is the one that gets used: most of what an admin wants is to make certain
sign-ups ask, and a server with only a yes and a no ends up shutting out a
university because one person there was a nuisance.

Where two lists disagree, the stricter answer wins. A refusal was the more
deliberate decision.

## Mail domains

Blocked by name, and the name covers its subdomains, or a block is undone by
whoever runs the domain pointing a subdomain at the same mail server.
`notbad.example` never matches `bad.example`, because matching is on label
boundaries.

A domain whose **mail servers** sit under a blocked domain is blocked too. A
disposable-address service runs a thousand domains off one set of MX records,
and blocking them one at a time is a game nobody wins. The lookup is injected
rather than hard-wired, so a test never touches DNS and a deployment can point
it at its own resolver; with no resolver configured, only the name is checked.

Tick **only ask for approval** for the softer answer.

## Email addresses

Stored as a **hash of the normalised address**, never the address. The list
exists to recognise somebody who was suspended coming back, which needs a
comparison and not the ability to read the addresses back out; an admin
database that leaks is then a list of hashes rather than a list of people.

Normalising drops case, removes a `+tag`, and folds dots **only at providers
that ignore them** (`gmail.com`, `googlemail.com`). Folding dots everywhere
would block strangers who happen to share a spelling.

## Addresses

A range or a single address, with three severities:

| Severity | Means |
| --- | --- |
| `sign_up_requires_approval` | They can sign up; a moderator reads it first |
| `sign_up_block` | No new accounts from here |
| `no_access` | The server answers 403 to every request from here |

Only `no_access` affects reading. A sign-up block says nothing about reading,
and treating one as the other would quietly wall off everybody behind a shared
address because one person misbehaved. The 403 carries a plain sentence, so
somebody behind a university NAT can find out it was deliberate and go and ask.

Set an expiry where you can. A residential address is somebody else's next
month, and a permanent block on one is a punishment aimed at a stranger. IPv4
and IPv6 both work; a bare address is that address alone.

## Usernames

Exact, or **anywhere in a name**. Matched against a normalised form: case
dropped, underscores and dots removed, and look-alike characters folded, so a
name spelled with a Cyrillic `а` is the same name as one spelled with a Latin
`a`. Spelling it that way is the entire point of spelling it that way.

The fold covers the characters actually used to impersonate an admin account
rather than the full Unicode confusables table, which is thousands of entries.

## The puzzle

Optional hCaptcha on sign-up, off unless both `HCAPTCHA_SITE_KEY` and
`HCAPTCHA_SECRET` are set. A server that quietly required a puzzle nobody
configured would refuse every sign-up with no explanation.

When it is on, a missing answer and an unreachable checker are both refusals. A
check that cannot be made must not pass, or the puzzle is decoration.

## Closing the door when nobody is watching

An **open** server that no moderator has signed in to for seven days closes its
own sign-ups. An open server left unattended fills with spam registrations
within days, and the admin who forgot about it is the one who finds out.

The change is written to the audit log with no actor, so somebody coming back
to a closed server can see it was the server rather than a colleague. Reopening
is a normal settings change.

## From a moderation client

Everything on this page is also reachable over the admin API, so a moderation
client can work the same lists:

| Family | Endpoint |
|---|---|
| Mail domains | `/api/v1/admin/email_domain_blocks` |
| Email addresses | `/api/v1/admin/canonical_email_blocks` |
| Addresses | `/api/v1/admin/ip_blocks` |

All three need `manage_blocks`. An address block can be edited in place
(`PUT /api/v1/admin/ip_blocks/:id`), which is how you soften or extend one
without it becoming two entries in the audit log for one decision.

`POST /api/v1/admin/canonical_email_blocks/test` answers which blocks an
address would trip without writing anything, using the same canonicalisation
the block itself uses — so it cannot say one thing there and another when the
block lands. Handy before blocking somebody, to see whether they are covered
already.

Allowing a domain (`/api/v1/admin/domain_allows`) sits with the domain blocks
under `manage_federation` instead, because it is the same decision seen from
the other side.

## What is recorded

Every sign-up stores the address it came from, so an address block written
afterwards means something and a wave of registrations can be seen for what it
is. The canonical email list is written to the log by the first twelve
characters of the hash: the address never reaches the log either.
