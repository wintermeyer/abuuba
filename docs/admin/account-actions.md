# Account actions, strikes and appeals

## The ladder

| Action | Does |
| --- | --- |
| `none` | Nothing but the warning itself |
| `disable` | The owner cannot sign in; everybody else still sees the account |
| `mark_statuses_as_sensitive` | Everything the account posts is flagged sensitive, before and after the decision, and travels flagged to other servers. The account's owner keeps seeing their own posts as they wrote them |
| `delete_statuses` | Deletes the posts named with the action |
| `silence` | The account stays reachable but drops out of public surfaces: the public and hashtag timelines, explore, trends, the directory and follow suggestions |
| `suspend` | Hidden from everybody, data purged after a grace window; the owner cannot sign in either |

Disabling and suspending both end the sessions and app tokens the account
already had, so the decision takes effect on the next request rather than the
next time somebody signs out. Every request checks in any case -- an account
that is suspended or disabled is refused by the API and by the pages here
alike -- but a session token that still works is a live credential, and
revoking the app tokens is also what closes a streaming connection, which
authenticates once when it connects.

`none` is a real action, not a placeholder. Telling somebody is a moderation
decision, and the most common one.

## What one action does

Every action does the same five things: applies the state change, records a
strike the account's owner can read, writes to the audit log, resolves whatever
report prompted it, and tells the person. They are written once, in
`Abuuba.Moderation.Actions.take/4`, rather than five times across five actions,
because the one that gets forgotten is the fifth. An account silenced without
being told is an account whose owner spends a week wondering why nobody
answers them.

Pass the report that prompted the action and it is closed by the same act. A
moderator who has taken the decision should not also have to remember to close
the thing that asked for it.

## Suspension keeps the data for 30 days

A suspension hides everything immediately and schedules the purge for later. An
appeal upheld after the purge is an apology with nothing to give back, and the
window is what makes reversing one mean something. Lifting the suspension
cancels the purge.

## What can be undone

Disabling, marking sensitive, silencing and suspending. Deleting posts cannot.
The ladder says so up front rather than discovering it at the moment somebody's
appeal is upheld and there is nothing to restore.

Undoing keeps the strike and marks it overruled. Deleting the record would
leave the appeal pointing at nothing.

## Appeals

One per strike, within 20 days. Somebody files one from **Settings →
Moderation**; a moderator answers it at `/admin/appeals`, which needs the
`manage_appeals` permission and is linked from the dashboard's "appeals
waiting" tile. Oldest first, because an appeal is somebody waiting on an
answer.

Upholding one undoes the action where it can be undone; where it cannot, the
appeal is still recorded as upheld, because the person was right and the record
should say so even when nothing can be given back. Turning one down leaves the
action standing. Either way the account owner is told, and either way the
decision goes to the audit log as `appeal.approve` or `appeal.reject`.

Somebody may only appeal their own strike, and the lookup is scoped to them
rather than checked afterwards: a query that cannot return somebody else's
strike cannot show them one.

## Notes

Free text against an account or a report, readable by moderators and never by
the account. "We have seen this pattern before" is exactly the sort of thing
that has to be written down and exactly the sort of thing that must not be
handed to whoever it is about.

## What a disabled account is told

Disabling and "waiting for a moderator to look at your registration" are the
same two columns underneath: approved, and whether approval ever happened.
Somebody who was let in and then disabled sees "This account has been disabled.
Contact the moderators."; somebody whose registration nobody has looked at yet
still sees that a moderator has to look at it. The message follows the state
rather than being chosen at the point of disabling, so a takeover from another
server gets it right without doing anything special.

## Memorials

An account whose owner has died can be marked as a memorial, from the account
page in the admin area. It is not on the ladder above and it is not a
moderation action: nothing is hidden, nothing is deleted, and no judgement is
being made. What changes is that the account can no longer be signed in to, and
clients mark the profile as a memorial rather than showing it as missing. The
posts stay exactly where they are and stay readable.

It can be undone, and it is written to the audit log either way, because it
disables somebody's login and a mistake has to be traceable to whoever made it.

## Warning presets

Named texts a moderator picks instead of retyping. Written under **Server
settings → Warning presets**, kept for the server rather than for one
moderator: two people writing to two accounts about the same thing should say
the same thing, and the account that got a curt sentence because it was a
Friday has been treated differently from the one that got the careful
paragraph.

On an account page, **Start from** fills the message box with the preset's
text, still editable before it goes. A preset is a starting point, not a form
letter. Saving one with a title that already exists replaces it, so the same
form edits and creates, and the list cannot fill with three slightly different
"Spam" entries nobody can choose between.

## Doing one thing to several accounts

**Administration → Accounts** has a tick box on each row and a bar above the
list. Filter first, tick what the filter found, choose limit, suspend, or stop
them signing in, and the confirmation names the count before it happens — a
mis-click here is expensive in proportion to how easy it is, so "are you sure"
on its own is not the question worth asking. Only accounts on the page you are
looking at are touched, and only those three actions: deleting somebody's posts
is the one action here that cannot be lifted afterwards, so it is not offered
over a list.

Each account goes through the same call as acting on one: its own strike, its
own notification, its own audit entry. "Who suspended this account" stays
answerable per account rather than pointing at a batch. Accounts that outrank
yours are skipped, and anything else that failed is counted separately from
those, so a batch that quietly did nineteen of twenty does not go unnoticed and
"it outranks yours" is never said about an account where that was not the
reason.

A batch strike carries no message. There is nowhere sensible to write one
paragraph that fits twenty different accounts, so the people caught by a batch
are told that something was decided and nothing more. Where the message
matters, act on the accounts one at a time — that page has the message box and
the preset picker.

## Not here yet

Email about a decision. The account owner is notified in the application and
sees the strike under **Settings → Moderation**; there is no mail delivery in
the project yet, and it arrives with the notification mailer.

## A note for the other moderators

A box on every account page. Nobody is told, nothing is applied, and the account
it is about never sees it.

It is for the context that otherwise lives in one person's head and leaves when
they do: that this is the third report about the same joke, that somebody spoke
to them and they understood, that the last suspension was lifted for a reason
worth remembering. Saving one is recorded in the audit log; the note itself is
not, so rewriting it does not leave the old text behind.

## Locked out, or somebody else is in

**Force a password reset** ends every session and every app the account has, and
emails its owner the ordinary reset link.

It deliberately does **not** choose a new password. A password a moderator
picked is a password a moderator knows, and the point of this button is to get
somebody back into an account that another person is in — which a shared
password does not do. The old password keeps working until its owner follows
the link, because until then nothing has been proven about who is asking.

## Their profile here is a copy

For a remote account, **Fetch it again** asks their server for the profile now
rather than waiting for the next thing they post — which, for the account you
are looking at on a bad morning, may be nothing at all.

## Their most recent posts

The last twenty, with a delete button on each. It is the same delete the account
holder would do themselves: other servers are told to delete their copies, and
the counters unwind. Deleting one is recorded in the audit log with the post's
id, so an account emptied by a moderator can be accounted for afterwards.
