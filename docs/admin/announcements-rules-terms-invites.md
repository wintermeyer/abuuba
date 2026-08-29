# Announcements, rules, terms and invites

The four ways a server talks to the people on it before anything goes wrong.

## Announcements

**Administration → Announcements.** Write one and it goes up immediately, or
give it a time and it publishes itself. That is what turns "the server is down
on Sunday" into something written on Thursday and forgotten about, rather than
something somebody has to be awake to press.

A scheduled announcement is published by a worker that runs every minute. The
update is conditional, so one is published once even if two runs overlap, and
anybody watching a stream is told at that moment rather than on their next
poll (`announcement` and `announcement.delete` events on the public topic).

Reactions and dismissals are per account, because a count is only meaningful if
it is a count of people, and an announcement everybody dismissed at once would
be one nobody could still be reading.

## Rules

**Administration → Server settings.** Ordered by position, shown before the
signup form rather than as a checkbox under it: that is the difference between
somebody having read them and somebody having ticked a box.

Each rule carries a translations map rather than being duplicated per language.
Two rows would be two rules that drift apart, and a moderation decision would
then be recorded against whichever language the moderator happened to be
reading. A rule with no translation for a reader's language falls back to the
text it was written in: a rule that disappears is worse than one somebody has
to read in the original.

`GET /api/v1/instance/rules` answers in the reader's language, resolved from
their account setting or their `Accept-Language` header.

Retiring a rule keeps the row, so an agreement recorded against it still refers
to something and a moderation decision taken under an old rule can still be
read years later.

## Terms of service

Versioned, never edited. Each version is a row with the day it takes effect,
and every older version stays readable at `/terms/YYYY-MM-DD` and at
`GET /api/v1/instance/terms_of_service/YYYY-MM-DD`. Editing in place would
leave every account that agreed to the terms pointing at words they never read,
and "what did I agree to in March" is the question terms exist to answer.

The effective date is a date rather than a moment: terms take effect on a day,
and a timezone-dependent instant is a promise nobody can read off the page. A
version dated in the future is published but not yet current, which is how
people get told before it applies.

**Tell everybody** writes one announcement rather than a notification per
account. There is no mail delivery in the project yet, and a row per person for
something everybody reads in the same place would be a hundred thousand rows
saying one thing. It can only be done once per version: an announcement written
twice is an announcement people stop reading.

## Invites

**Settings → Invites**, for anybody holding `invite_users`. The list is the
holder's own; an invite names who vouched, and a list of everybody's would tell
one person who else is vouching for whom.

Codes avoid `0`, `O`, `1`, `I` and `l`. An invite is typed by hand off a phone
screen or read out across a table more often than it is clicked, and a code
nobody can transcribe generates a support conversation instead of an account.

| Field | Means |
| --- | --- |
| Uses | Empty for as many as you like. Zero would read as none, which is the opposite of what an empty field meant |
| Expiry | Optional |
| Autofollow | The new account follows whoever wrote the invite |

An invite lets somebody in when sign-ups are **closed** and skips the approval
queue when they are **moderated**: somebody vouched for by a person here has
already been through the check that approval exists to make. They are not asked
why they want to join for the same reason. A code that is wrong is refused
outright rather than quietly ignored, because somebody who typed one meant to
use it.

Spending a use is a conditional update, so two people racing for the last use
of a single-use invite cannot both win.

`GET /api/v1/invites`, `POST /api/v1/invites`, `DELETE /api/v1/invites/:id`.
