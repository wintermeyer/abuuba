# Admin guide

For whoever runs the server. Installing it is in
[deploying abuuba](../deploy.md); everything here is about running it once it is
up.

## Start here

- **[The admin area](admin-area.md)** — where the controls are, and who can
  see them.
- **[Roles and permissions](roles.md)** — what a moderator can do that an
  admin can, and the other way round.
- **[Configuration](configuration.md)** — every environment variable, and the
  settings that live in the database instead.

## Moderation

The handbook, roughly in the order a report travels:

- **[Reports](reports.md)** — what arrives, and how to work through it.
- **[Account actions, strikes and appeals](account-actions.md)** — what you can
  do to an account, and what the person sees.
- **[Blocking other servers](domain-blocks.md)** — suspension, silencing, media
  rejection, and what each one does to what is already here.
- **[Keeping abuse out at the door](signup-blocks.md)** — email rules, the
  puzzle, approval mode.
- **[Announcements, rules, terms and invites](announcements-rules-terms-invites.md)**
  — the instance's own words.

## Federation

- **[When another server stops answering](federation-health.md)** — what abuuba
  does about it, and when it gives up.
- **[Relays](relays.md)** — subscribing to a firehose, and what it costs.
- **[Feeds](feeds.md)** — how a home timeline is built, and why it is written
  rather than queried.

## Content

- **[The media pipeline](media.md)** — what happens to an upload.
- **[Where media lives](media-storage.md)** — local disk, S3, a CDN in front of
  either.
- **[Link previews](preview-cards.md)** — when a card is fetched and when it is
  not.
- **[Search](search.md)** — what is searchable, by whom.
- **[Trends](trends.md)** — how something becomes trending, and how to stop it.
- **[Translating posts](translation.md)** — wiring up a translation service.
- **[Rate limits](rate-limits.md)** — the defaults, and reading the client
  address behind a proxy.

## Moving in

- **[Taking over a Mastodon instance](importing-from-mastodon.md)** — the
  import, what it moves, and why the domain has to stay the same.
- [Webhooks](webhooks.md) — telling another system when something happens here
- [Other servers](instances.md) — who this server talks to, and whether it is getting through
- [Operational commands](mix-tasks.md) — the verbs an admin reaches for at a terminal
