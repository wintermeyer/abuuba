# Reports

## What a report is

Somebody saying an account has done something wrong. It names the account, a
category, optionally some of its posts as evidence, and optionally which rules
it broke.

**Nothing happens automatically.** Filing a report notifies the moderators and
puts a row in a queue. It does not hide, suspend or delete anything. Anything
else would make the report button a weapon.

## Categories

| Category | Means |
| --- | --- |
| `spam` | Unwanted commercial or repetitive posting |
| `legal` | Something illegal in the server's jurisdiction |
| `violation` | Breaks one or more of the server's rules, named in `rule_ids` |
| `other` | Everything else, explained in the comment |

They are the reference implementation's four, so a client that can file a
report against one server can file the same one here. A category this server
does not recognise becomes `other` rather than being refused: the complaint is
what matters, and losing it over an unfamiliar word would be losing the thing
the endpoint exists for.

## Evidence

A report may name posts. Only posts the reported account actually wrote are
kept — a report naming somebody else's posts would put those in front of a
moderator as though the reported account had written them.

Comments are capped at 1,000 characters. Reporters are rate limited like any
other action.

## Who is told

Everybody holding `manage_reports`, **once per account under complaint** rather
than once per report. Ten people reporting the same account in the same minute
is one thing a moderator has to look at, and a notification each turns a
brigading incident into a denial of service against the people handling it.

Once the open reports against that account are resolved, the next one notifies
again.

## The queue

**Administration → Reports**, which needs `manage_reports`. Open reports by
default; the picker at the top asks for the ones already dealt with, or for
everything. A queue that shows every report ever filed is a queue nobody works.

Reports are unresolved until somebody says otherwise.

- **I am on this** puts one in a moderator's hands, so two do not reach two
  different decisions about the same report.
- **Mark it dealt with** closes it, including "nothing was needed" — a queue
  where no-action cannot be recorded is a queue that never empties.
- **Put it back in the queue** reopens it.

Opening a report shows what the reporter wrote, the posts it names, and the
account it is about, with a link to that account's page for taking action.

## Notes on a report

Under the report, a thread any moderator can add to. This is where "checked the
other three, same person" goes: two people working the same queue can see what
the other found, and neither has to reconstruct it from the audit log.

Notes are moderators-only. Neither the account reported nor whoever filed the
report ever sees them, which is what makes them worth writing honestly. They
are kept with the report and are never sent anywhere.

## The history

Every step writes to the audit log: who did it, what, to which report, and any
reason given. Oldest first, because it reads as a story.

The log is what one moderator reads to find out what another already decided,
what an account's owner is answered with when they ask why they were suspended,
and what an appeal is judged against. It is append-only: a log somebody can
tidy is a log nobody can rely on.

## Forwarding

A report about an account on another server names somebody this server cannot
suspend. Only their own server can act, and if nobody tells them they never
learn there was a problem.

**Forwarding is opt-in per report.** It tells that server who complained, which
is a real cost to the reporter borne under somebody else's moderation, and it
is not ours to decide on their behalf.

A forwarded report goes to the reported account's server and to the servers
hosting anybody being replied to in the evidence — a reply is a conversation,
and the server on the other side is the one that can see the rest of it. The
activity is signed by this server rather than by the reporter, and carries the
report's own id so a redelivery is recognised as the same report.
