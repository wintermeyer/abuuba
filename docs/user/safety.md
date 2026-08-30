# Safety

Four tools that do four different things. Reaching for the wrong one is the
usual reason somebody is still unhappy after using it.

| You want | Use |
| --- | --- |
| To stop seeing somebody, quietly | Mute |
| To stop them seeing you as well | Block |
| To stop seeing a subject, whoever posts it | A filter |
| A moderator to look at somebody | A report |

## Muting

On their profile: **Mute**. Their posts leave your timeline and their
notifications stop reaching you.

They are not told, they can still follow you and still read you, and you can
undo it in the same place. It is the polite instrument, and the right one for
somebody you know but do not want in your feed today.

Muting works backwards as well as forwards. Your timeline is filtered as it is
drawn, so what they posted before you muted them goes too, on the next reload.
Nothing is deleted, which is why unmuting brings all of it straight back.

Muting reaches everywhere posts are shown, not only the timeline: they are
gone from search results, from explore, from every hashtag page and from the
replies under a thread as well, and so is anything of theirs that somebody
else boosts.

## Blocking

On their profile: **Block**. Everything mute does, plus: they cannot follow
you, any follow either way is undone, and what they already put in your
timeline is taken back out of it. While they are signed in, your profile
answers them with nothing: no posts, no pinned posts, and neither of your
follow lists. Apps get the same empty answer as the web page.

A block covers their words wherever they turn up, including in somebody
else's boost, in a thread, in search, and on any profile that boosted them.
The one place you still see them is their own profile, if you go and look:
opening it is your decision, and a block is about what reaches you.

## Blocking a whole server

At `/settings/filters`, under **Blocked servers**: some servers are more
trouble than the accounts on them. Blocking a domain shuts out everybody there at once —
nothing of theirs reaches your timelines, your search results, your threads or
your notifications, and their boosts are gone with them. Existing follows in
either direction go the way they do for a personal block.

Blocking is visible in the sense that they will notice they can no longer see
you. Nobody sends them an announcement.

**What blocking cannot do.** This is a network of independent servers. A
blocked person can sign out and read your public posts like any stranger, and a
determined one can make another account. Blocking makes somebody go away; it
does not make you invisible. If what you post needs to be seen only by people
you have approved, set your posts to followers-only and approve your followers
— see [posting](posting.md) and the Privacy section of
[settings](settings.md).

## Filters

At `/settings/filters`: words and phrases you would rather not see, whoever
posts them. Each filter says **where** it applies — home, notifications, public
timelines, threads, profiles — and **what** it does: fold the post behind a
warning you can open, or hide it completely.

Folding is usually the better default. A filter that hides is a filter you
cannot tell is misfiring.

## Deciding who can reach you

`/settings/notifications` takes six kinds of sender — people you do not follow,
people who do not follow you, very new accounts, private mentions from somebody
who is not replying to you, accounts a moderator has limited, and automated
accounts — and lets you accept, filter, or ignore each. Where a sender is more
than one of those, the strictest answer wins.

**Filter is the reversible one.** It puts them on a waiting list on that page
where you can still read them and let them through. **Ignore keeps nothing**,
so there is nothing to change your mind about. Prefer filter unless you are
certain.

Fuller description in [notifications](notifications.md).

## Follow requests

If you turned on **Approve followers first** under privacy, nobody follows you
without your say-so. Whoever is waiting is on their own page, and the
navigation shows a **Follow requests** entry with a count for as long as
somebody is — it is not there when nobody is waiting, which on most accounts
is always.

**Let them follow** or **Turn them away**, one at a time. Turning somebody away
tells them nothing and leaves no mark, so they can ask again; there is no way
to refuse somebody permanently short of blocking them.

## Reporting somebody

Reports go to the moderators of this server, and — if you choose — to the
moderators of the sender's server as well.

**Report** is on a profile beside Mute and Block, and under the **…** on any
post. It asks four short questions: what kind of problem it is, which rules it
breaks if you picked that, which posts a moderator should read, and anything
you want to say in your own words. Nothing is sent until the last press.

The first option is **I do not like it**, and it files no report at all. It
goes straight to mute and block, because that is what it is: something you do
not want to see rather than something a moderator can decide. Mute and block
are offered after a real report as well — somebody has to read it, and in the
meantime you do not have to keep seeing the person.

The rules question only appears if this server has written any down. Where an
account is on another server you are also asked whether to send a copy of the
report there, without your name. Forwarding is worth it for spam and worth
thinking about for a personal dispute, since it tells the other side that
somebody here complained.

## Forgotten your password

`/reset-password`, linked from the sign-in page. Give the address you signed up
with and a link comes back by email. The link works once and lasts six hours.

The page says the same thing whether or not the address has an account here.
That is deliberate: if it said "no such account", anybody could use the form to
find out who is on this server, and that list is worth having to whoever writes
phishing mail.

Setting a new password signs you out everywhere, apps included. That is the
point rather than a side effect — most people resetting a password think
somebody else is in their account, and an app left signed in keeps them there.

Two things a reset does **not** change. It does not turn off two-step sign-in:
a reset proves you can read your email, and reading your email is exactly what
the second step exists to survive. And if you never confirmed your address,
following the link confirms it, because it is the same proof.

You get a second email telling you the password was changed. If one of those
arrives and it was not you, ask for a new password immediately and tell the
people who run the server.

## Two-step sign-in

`/settings/two-factor`. Your password plus a code from an app on your phone, so
that a stolen password on its own is not enough.

Keep the recovery codes it gives you somewhere that is not the phone. Losing
both the phone and the codes means losing the account, and no moderator can
turn that off for you.

While you are in that part of settings: **sign out everywhere**, on the
security page, ends every session including the one you are using. That is what
to do from a borrowed computer you forgot to sign out of.

## If your account is limited

If a moderator acts on your account you are told what happened and why, and
there is an appeal button. It is on `/settings/moderation`, along with anything
that has already happened to the account. The moderators' side of the same
process is in the admin guide, under
[account actions, strikes and appeals](../admin/account-actions.md).
