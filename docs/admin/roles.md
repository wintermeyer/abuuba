# Roles and permissions

## What a role is

A name, a colour, whether it shows as a badge, a position, and a set of
permissions. Roles are yours to define: there is no built-in "moderator" whose
meaning is fixed in the code.

Somebody with no role gets whatever the **everyone** role grants, which is
nothing until you change it. That is also what a signed-out visitor gets, which
is to say nothing at all.

Which of these permissions opens which part of [the admin area](admin-area.md)
is listed there.

## The permissions

| Permission | What it allows |
| --- | --- |
| `administrator` | Everything, including permissions added in future versions |
| `devops` | Operational dashboards |
| `view_audit_log` | Reading what other admins did |
| `view_dashboard` | The admin dashboard |
| `manage_reports` | The reports queue |
| `manage_federation` | Domain blocks and relays |
| `manage_settings` | Server settings |
| `manage_blocks` | Email and IP blocks |
| `manage_taxonomies` | Hashtags and trends |
| `manage_appeals` | Appeals against moderation |
| `manage_users` | Accounts and their moderation state |
| `manage_invites` | Invitations |
| `manage_rules` | The server rules |
| `manage_announcements` | Announcements |
| `manage_custom_emojis` | Custom emoji |
| `manage_webhooks` | Webhooks |
| `invite_users` | Creating invitations for oneself |
| `manage_roles` | Roles themselves |
| `manage_user_access` | Resetting passwords and two-factor |
| `delete_user_data` | Erasing an account's content |

They are stored as one number, a bit each, using the same bit positions as the
reference implementation so that a client which knows one server does not have
to translate for this one.

**`administrator` is a short circuit, not twenty flags.** It answers yes to
every permission there is, including ones added later. Granting it is granting
everything, permanently.

## The first one

A fresh database has no roles at all, so the admin area is a door nobody can
open. One command makes the first account that can:

```sh
bin/abuuba eval 'Abuuba.Release.bootstrap_owner(%{username: "alice", email: "alice@example.com"})'
```

From a checkout, the same thing through the same code:

```sh
mix abuuba.accounts bootstrap-owner alice --email alice@example.com
```

It prints a generated password once. That is the only time it exists in
readable form, because the column holds a hash, so losing the line means
sending a reset rather than looking it up. The account is confirmed and
approved on the way in: there is nobody to send a confirmation link to on a
server whose mail is probably not configured yet, and nobody to approve it but
itself.

Run it again for a second admin and it reuses the role rather than adding
another. Note that `mix abuuba.accounts create --role Owner` cannot do this job —
it assigns a role by name, and a fresh database has no role to name.

In development that happens on its own: the first account registered on an
empty database is given an `Owner` role with every permission, so a fresh
checkout has somebody who can get in. It is also let past the sign-up approval
queue, because on a server that moderates sign-ups the founder would otherwise
be waiting for the only account that could approve it, which is itself. It
still has to confirm its email address; the link is in the development mailbox
at `/dev/mailbox`.

Switched on by `config :abuuba, first_user_is_admin: true` in `config/dev.exs`
and nowhere else, deliberately — on a public server it would mean whoever signs
up first owns the place.

Once a role with `administrator` exists, nothing creates a second one. Two
roles that both mean "can do everything" is the state where taking somebody's
access away appears to work and does not.

## Position, and who may act on whom

Every role has a position. Higher acts on lower, and **nobody acts on a peer**.

That single rule is what stops two moderators unmaking each other, and what
stops anybody promoting themselves. An administrator outranks everybody
whatever the positions say, which is what makes them able to untangle a
hierarchy somebody else has knotted.

Somebody with no role sits below every real one, so any role at all is enough
to act on somebody who has none.

## The three rules around editing roles

Editing roles is the permission to watch, because it is the one that can become
every other permission. Three checks stand between it and that:

1. **You cannot edit the role you hold.** Otherwise granting yourself anything
   is one form submission.
2. **You cannot edit a role at or above your own position.** Otherwise you
   demote whoever would have stopped you.
3. **You cannot put a permission on a role that you do not hold yourself.**
   Otherwise you build a role more powerful than you, hand it to a friend, and
   they hand it back.

Remove any one of the three and there is a path from "can edit roles" to "can
do everything". An administrator is exempt from all three, which is what being
an administrator means.

## Checking a permission

Both surfaces use the same check, so they cannot disagree:

```elixir
# In a controller
plug AbuubaWeb.Plugs.RequirePermission, "manage_reports"

# In a LiveView
on_mount: [{AbuubaWeb.AdminAuth, {:require, "manage_reports"}}]
```

A refusal is 403 rather than 404: the person is authenticated and the route
exists, and pretending otherwise sends an admin hunting for a typo in a URL
that was right.

Clients read somebody's role from `GET /api/v1/accounts/verify_credentials`,
which is how they know which admin surfaces to offer.

## The editor

**Administration → Roles**, which needs `manage_roles`. List, create, edit and
remove roles; each permission is a checkbox with what it actually does written
next to it, because `manage_taxonomies` is a word this project made up and the
person ticking the box has to know what they are handing over.

Two guard rails, and both are checked on the server rather than only in the
markup — a hidden button is not a check, and somebody can always send the event
anyway.

**Nobody may make or touch a role at or above their own position.** A role at
your own position is a role that can edit you. Editing a role you *may* touch
into a position you may not is refused for the same reason: it is the same
escalation in two steps.

**Nobody may grant a permission they do not hold.** The box is disabled and the
bit is refused if the event arrives anyway. A permission you do not hold is
left on the role exactly as it was rather than dropped, so editing a role does
not quietly strip something you could not see.

Creating, changing and removing a role are all recorded in the audit log with
the role's name, because a role is a standing grant of power on this server and
who widened it should be findable afterwards.

Assigning a role to somebody is on that account's own page under
Administration → Accounts.
