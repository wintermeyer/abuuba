# Settings

Everything about your own account lives under `/settings`, one section per
address, all in the same interface. There is no seam where the layout and the
navigation change under you.

## Profile

Your display name, what you say about yourself, and up to four fields: a label
and a value each, shown on your profile in the order you put them in.

A field whose value is a link can earn a **Verified** mark; see
[Profiles](profiles.md) for how the check works and what it will not fetch.

An avatar and a header image cannot be uploaded on this page yet. An app that
speaks the Mastodon API can set them today.

## Appearance

Reduce motion, higher contrast, your system's font, and not playing media on
its own. Each of these follows your operating system unless you set it here, so
this is an override for when your system setting is wrong for you.

The missing-description reminder for pictures is here too.

Dates and numbers follow whatever language the interface is in, so a German
page writes `05.12.2026` and `1.234,5` where an English one writes
`Dec 5, 2026` and `1,234.5`. The language comes from your own setting first,
then the one you picked in this browser, then what your browser asks for.

## Posting

What the compose box starts with: who new posts go to, who may quote them, and
the language you usually write in.

"Only the people you name" is deliberately missing from the audience list. As a
default it turns every post you forget to change into a message to nobody.

**Say which app you posted from** is on to start with. Apps show it under a
post — "via Ivory" — and people use it to tell the things they sat down and
wrote apart from what a bot or a scheduler sent. Turn it off and it disappears
from your posts for everybody else; you still see it on your own, because
forgetting which app you wrote something in is not what you asked for. It only
covers posts written here: what a post from another server says is that
server's business.

## Pinned posts and deleting your old ones

Both on the **Posting** page.

**Pinned posts** are what sits at the top of your profile. You pin one from the
post itself; this page is where you see the list and take one back off.

**Delete my old posts** is off unless you turn it on, and stays off if you
leave the age empty. Set an age in days and everything older goes, a batch an
hour, with the exceptions you choose: keep pinned posts (on by default), keep
posts with pictures or video, and keep anything favourited or boosted at least
so many times. Somebody using this is usually saying "the chatter goes, the
things that mattered stay", and those thresholds are how you say which was
which.

The page tells you how many posts match before you save, because being told
"this will delete four hundred posts" beforehand is the difference between a
setting and a surprise. Posts go the same way one does when you press delete on
it: other servers are told, and it cannot be undone.

## Privacy

| Setting | What it does |
| --- | --- |
| Ask before letting somebody follow you | Every follow becomes a request you answer |
| List me in the directory | Your account appears on this server's public directory page |
| Let search engines index my posts | Off to begin with. While it is off, your profile and your posts ask crawlers to skip them; applies to public posts only |
| Hide who I follow and who follows me | The lists stop being public, and the featured accounts strip on your profile goes with them; the follows still work |
| This account posts automatically | Marks it as a bot, which some people filter on |

**Sites that may name me as an author** is the box under those switches. Write
one domain per line — `example.com`, or paste the whole address and the scheme
is trimmed off. When somebody shares a link to a site you have listed, the
preview card credits you as its author, with your name and picture.

It works this way round because the claim is written by whoever runs the site.
A page can say it was written by anybody; listing the domain here is you
agreeing to it. A site you have not listed cannot put your name on its links,
however its page is written. Leave the box empty and nobody can.

**Featured hashtags** are shortcuts to what you write about, shown on your
profile with a count of how many public posts carry each. Type one in, or take
one of the suggestions — those are tags you have used more than once and have
not featured yet. The count only ever includes posts a visitor could see.

## Email updates

This only appears when the admin has turned it on for the server. It lets
somebody who does not want an account here give an email address instead and
read what you write.

Turning it on shows how many addresses have confirmed. Nothing is sent to an
address until the person behind it has confirmed it themselves, and an address
that has not confirmed gets at most one message a day however many times the
form is submitted — so an address somebody typed in by mistake, or on purpose,
cannot be mailed repeatedly. An address that never answers is deleted after a
week. Every message carries a link that stops the updates, and following it
needs no account and no password.

Turning it back off stops new subscriptions. It does not delete the addresses
that already confirmed.

Once somebody has confirmed, a **Write to them** box appears under the switch:
a subject, a message, and it goes to every confirmed address. Up to four
messages a day, and what you have sent is listed underneath with the date and
how many addresses it reached. Every message carries the same unsubscribe link,
and mail clients that offer their own "unsubscribe" button find it in the
headers.

People subscribe from your profile page: when this is on, a short form sits at
the bottom of the profile header asking for an address. There is nothing to copy or share beyond
your profile's own address.

## Filters

Words and phrases you would rather not see. A filter names where it applies
(home, notifications, public timelines, threads, profiles), the words to look
for, one per line, and what it does: fold the post behind a warning, or hide it
completely.

Filters match whole words unless you say otherwise, so "cat" leaves
"concatenate" alone. Untick that box for a filter meant to catch a fragment.
Matching ignores capitals, and it reads the content warning as well as the
post, because a warning is exactly where somebody names the topic.

These pages honour them. A post a **fold** rule matched appears as one line
naming the rule, with **Show anyway** beside it, so you can lift your own rule
for one post without going back here. A post a **hide** rule matched is not
drawn at all, and the rule's name is not either — hiding is asking not to be
told there was something to see.

It applies wherever posts are listed: your home timeline, a hashtag, a profile,
and a thread, each according to the places you ticked. The one exception is a
post you opened yourself: following a link to a post is asking for that post,
so it is shown even where your rules would have folded it in a list.

Nothing is deleted or hidden from you by the server: a filtered post still
arrives, and it is your own copy of the page that folds it away or drops it.
That is what makes lifting a filter show you what you missed.

An app can also add one specific post to a filter, for the one that gets past
the words — the post that talks about the thing without ever naming it. This
web interface has no button for that yet; apps that speak the Mastodon API do.

## Follows

Everybody you follow, with a checkbox each. Tick several and unfollow them in
one press rather than one at a time.

## Security

Change your password, which needs your current one: otherwise somebody who
walks up to an unlocked screen owns the account.

Two-factor authentication has its own page. **Sign out everywhere** ends every
session including the one you are using.


**Recent sign-ins** lists the last attempts on your account with the time, the
address they came from and the browser — the failed ones too. Somebody else
trying your password is the thing worth spotting early, and nothing else here
would tell you. The list is kept for 30 days and then deleted: it exists to
answer "was that me last Tuesday", not to be an archive of where you have been.

## Apps

Apps you have signed in to with this account. Taking one back out revokes every
token it holds for you, so an app signed in twice does not stay signed in once.

Each app is listed with what it may do, in the same words the sign-in screen
used when you let it in: reading your timelines, posting for you, following
people on your behalf, and so on. Those are limits, not labels. An app that
only asked to read cannot post even if it tries, and the server refuses it
rather than trusting the app to behave.

An app signed in twice holds two sets of permissions, and the row shows both
together — the question you are asking is what that app can reach, not which
of its sign-ins can reach it. If an app later needs something it did not ask
for, it has to send you back through the sign-in screen, and you see the new
list before you agree.

## Account

Your other accounts, one web address per line. Naming an account here is what
lets you move to it later, and it only counts if that account names this one
back.

Moving to another account is on this page too, described
[below](#moving-to-another-account). Exporting what you have and deleting the
account are not here yet.

## Invites

Only if whoever runs this server has given your account the permission. A code
somebody can sign up with, even when sign-ups are otherwise closed, with an
optional limit on how many people may use it and an optional expiry. Ticking
"they follow you" means whoever arrives on it starts out following you, which
is usually the point: you already know each other.

Codes leave out characters that look like each other, so one can be read out
across a table without anybody having to spell it.

Send the short link, `https://this-server/invite/CODE`. It opens the sign-up
form with the code already filled in, and somebody arriving that way is not
asked why they want to join, because you have already answered that. A code
that has expired, been used up, or was mistyped still lands on the form and
says which of the three it was — three different things to the person holding
the link, and they should not have to ask you which happened.

## Import

Every fediverse server can give you a zip of everything you posted, and until
now no server could read one back. **Settings → Import** takes one: your posts
come back with their pictures and their original dates, so your profile reads
in the order you wrote it rather than as a wall of posts dated today.

Some things cannot come with them, and it is better to know before you start
than to notice a week later:

- **The old addresses.** Your posts lived on another domain and cannot live
  there again. Every link anybody ever shared to one of them stays broken;
  the copies here have new addresses.
- **Your followers.** A follow is an agreement between two servers, and one of
  them is gone. The people who followed the old account have to follow this
  one.
- **Boosts and polls.** A boost points at somebody else's post, which the
  archive does not contain. A poll's votes were counted somewhere else and
  could not be true here.

Imported posts stay out of everybody's home timeline and off the network. They
are years old, and nobody's followers asked to be shown a decade of somebody
else's history in one go.

Favourites and bookmarks are looked up by address, so they come back if the
post is still somewhere. One that cannot be found is listed rather than
silently dropped.

Reading an archive takes minutes rather than seconds, so it runs in the
background: closing the tab does not stop it, and coming back to the page shows
where it got to and what it could not bring over.

### Lists

The same page takes the CSV files your old server gives you: follows, blocks,
mutes, domain blocks, lists, bookmarks and filters. Upload them one at a time,
under the names they came with — the file is identified by what is inside it
first and by its name second, and one that is neither is refused rather than
guessed at, because reading a block list as a follow list would have you follow
the accounts you were hiding from.

**Add to it** leaves what you already have and adds what is in the file.
**Replace it with the file** makes what you have match the file, which is what
you want after editing an export. Bookmarks and filters are never emptied that
way: a reading list built over years is not something to clear on the way to
applying a file of twelve.

Every row is its own attempt. A follow list from a server that has closed names
accounts on a hundred others and some of them will be gone; those are listed by
name and the rest carry on.

## Moving to another account

**Settings → Account** moves this account to another one and tells every server
that follows you.

Two things have to be true first. The other account must name this one in its
own aliases — that is the half only you can arrange, and without it anybody
could name any account as their destination and be handed a follower list. And
you cannot have moved in the last 30 days, because moving repeatedly is how a
follower list gets walked across the network faster than anybody can notice.

Your followers on this server are moved over here. Everybody else's server gets
the notice and decides for itself, which is the only thing this server may do
about followers it does not hold.

If you come back, **I came back** clears the pointer so servers stop forwarding.
It does not reset the 30 days.

### After a move

If you approve your followers by hand, everybody who followed you arrives at
once, because every one of their servers acts at the same moment. **Accept all**
answers the lot, which is the same answer you already gave them.

## Moderation

What a moderator here has decided about your account, oldest decision last.
Each entry says what was done, when, and whatever the moderator wrote to you
about it. It is the same text they saw, not a summary of it.

If you think a decision was wrong you can appeal it once, within 20 days. Say
why in the box and the moderators see it in their queue. Whichever way it goes
you are told, and the page then says so instead of offering the form again.

One appeal per decision, not one per attempt. Appealing repeatedly until a
different moderator happens to be reading is a lottery rather than an appeal.

A decision that was later lifted stays on the page, marked as lifted. Erasing
it would leave your own appeal pointing at nothing.

The same page lists what this server's decisions about **other servers** cost
you. When it stops federating with one, the follows between you and the people
there are deleted in both directions. That cannot be undone from here: the
other side is no longer reachable to ask, and a follow is that server's record
as much as ours. What you can still see is which server it was, how many
relationships it cost you, and when.

## Export

Two different things, on the same page.

**Lists** are one CSV each: follows, blocks, mutes, lists, blocked servers,
bookmarks, filters. They download straight away and they are in the format this
server's import reads, so an export from here is an import somewhere else. That
round trip is the point.

**A copy of everything** is your profile and every post as JSON, with the CSVs
alongside and your favourites and bookmarks as their own lists of addresses,
in one zip. Those two lists are what an *archive* import reads, here or
anywhere; the CSV of the same name is what another server's settings import
reads. Both are in the file, because they are two different jobs rather than
one written twice. It is built in the background because it walks your whole
account, and you get an email when it is ready. One a week, and the file
is deleted after two days: it is your entire account in a single file, and
there is no good reason for it to sit on a disk longer than it takes you to
download it.

Pictures and video are **not** inside the zip. It holds their addresses, which
work for as long as this server does. If that matters to you, save them before
you close the account rather than after.

## Closing your account

At the bottom of the export page, behind your password. Your posts, pictures,
follows, lists, filters, bookmarks, sessions and apps are deleted -- the
pictures as files on the disk, not only as rows -- and every server that heard
from you is told to delete its copy. It cannot be undone.

The account disappears the moment you confirm: nothing of it is visible, and
nobody can sign in to it. The rows themselves are deleted a short while later,
and that gap is deliberate — the message telling other servers is signed with a
key that lives on the account, so the account has to outlive its own
announcement by long enough to make it.

Your **username is kept and nobody can ever have it again**. That is not an
oversight: every old mention, link and screenshot of your name would otherwise
point at whoever registered it next, which is impersonation that nobody had to
intend.

Take your copy first. There is nothing to export afterwards, and any archive
you had already built is deleted with the account rather than waiting out its
two days.

### Your pictures

An avatar and a header, both on the Profile page. JPEG, PNG, GIF or WebP, up to
8 MB — stated before you pick a file rather than after a failed upload.

What you send is scaled down here, once, to what the largest place it appears
actually needs. Nobody reading your posts should be fetching a four-thousand
pixel photograph to see it at forty.

**Take it off** removes one. There is no default picture underneath: a profile
without one shows no picture rather than a grey silhouette somebody has to
recognise as meaning "none".
