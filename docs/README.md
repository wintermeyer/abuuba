# abuuba documentation

Two guides, for two audiences.

- **[User guide](user/)** — for people with an account here. How to post, who
  can see it, how to find people, and what to do about somebody you would
  rather not hear from.
- **[Admin guide](admin/)** — for whoever runs the server. Moderation,
  federation, media, and the settings that decide how the instance behaves.
- **[Deploying abuuba](deploy.md)** — installing it, upgrading it without
  dropping requests, and what to back up.

## How these stay current

Documentation that describes last year's product is worse than none, because
somebody follows it. So a page here is part of the feature rather than a
write-up of it: every change to user- or admin-visible behaviour updates the
pages it affects in the same commit, and that is written into the project's
definition of done.

If you find a page that does not match what the software does, the page is the
bug. Open an issue.

## Language

The user guide is also in German, under [`de/user/`](de/user/). Both are
maintained: a change to an English user page changes the German one in the same
commit, the same rule the interface strings follow.

The admin guide and the deployment documentation are English only. They track
the code closely enough that a translation would go stale between releases, and
a German page describing an option that has since moved is worse for an
operator than an English one that is right.
