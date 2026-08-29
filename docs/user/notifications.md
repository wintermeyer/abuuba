# Notifications

## The column

Things that happened while you were away, newest first: somebody mentioning
you, favouriting or boosting or quoting one of your posts, following you or
asking to, editing a post you boosted, and a poll you voted in closing. Events
that belong together are one line: twelve people boosting the same post is one
thing that happened, not twelve, and the post itself is shown once underneath.

A poll closing reaches its author as well as everybody who voted, since the
answer is the part that arrives after the post does.

Taking something back takes its notification with it. Somebody who unfavourites
or unboosts your post, or who unfollows you, leaves nothing behind saying they
did it, and deleting a post clears the notifications about it. A line that
outlived the thing it described would be worse than no line: you would be
looking at a follow that is not there, next to a button offering to follow
back.

**Dismiss** removes one line. **Clear all** removes everything. Neither tells
anybody else.

## Being told when somebody posts

Following somebody puts their posts in your timeline. If you want to be told
about them as well, the profile of somebody you follow has **Tell me when they
post**, and from then on their posts arrive here too.

It is for what they write rather than everything they do. Their boosts are not
announced, and neither are their replies to other people — otherwise one busy
conversation would fill this column. A reply to their own post does count,
because that is somebody carrying on a thread you asked to hear.

## Your year

In the last three weeks of December, if you have posted more than once that
year, an app can offer you a year in review: how much you wrote month by month,
how many people started following you, the hashtags you used most, and the three
posts that travelled furthest. You get a notification when it is ready.

It is worked out from your **public and unlisted posts only**. That is what
makes the page at `/@you/year/<year>` safe to hand to somebody: it says nothing
a visitor could not have counted by scrolling your profile, and a report that
counted followers-only posts would publish how much you write where nobody can
see it.

The web interface shows the page. Asking for one is something apps do.

## Filters

**All** and **Mentions** are the quick switch, and each is its own address, so
you can bookmark the one you use.

Underneath it is a per-type list: mentions, boosts, follows, follow requests,
favourites, polls, edits, and posts from people you watch. What you tick is
remembered, because a filter you have to set again every visit is one nobody
uses.

The quick switch wins over the ticks. Clicking a tab called Mentions and
getting an empty page because of a checkbox you set weeks ago would be a trap
rather than a filter.

## The unread count

The number next to Notifications in the sidebar counts what arrived since you
last marked the column read. **Mark as read** moves that line to the newest
thing there is. It stops counting at a thousand, because nobody reads the
difference between 1,200 and 4,000.

## Who can reach you

`/settings/notifications` describes six kinds of sender and what happens when
one of them notifies you.

| Decision | What happens |
| --- | --- |
| Accept | It reaches you like anything else |
| Filter | It goes to the waiting list on this page, where you can still read it |
| Ignore | It is dropped, and nothing anywhere remembers it |

**Ignore cannot be undone.** Nothing is filed, so there is nothing to go back
to. Filter is the reversible one, and it is the right choice unless you are
certain.

The six kinds are: people you do not follow, people who do not follow you,
accounts made very recently, private mentions, accounts a moderator has
limited, and automated accounts. If a sender trips more than one, the
strictest answer applies: somebody who is both brand new and a bot has tripped
two, and you set both for a reason.

The private-mentions one has two exceptions, both there so that a message you
were waiting for is not filed somewhere you have to go looking. It does not
apply to somebody you follow, and it does not apply to a reply in a
conversation you started — if you wrote to them first, anywhere up that
thread, their answer reaches you.

## The waiting list

Anybody your settings filed sits at the top of the notifications page, one line
per person with a count of how much of them there is. It is on the page rather
than behind a setting, because the whole reason it exists is that its contents
might matter.

**Let them through** moves everything they sent into the main column and stops
filtering them from now on. **Not now** hides the line and keeps them filtered;
if they notify you again, the line comes back.
