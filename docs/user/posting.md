# Posting

## Writing a post

The compose box takes plain text. There is no formatting: `**bold**` reaches
your readers as four asterisks and two words, because that is how the rest of
the fediverse renders it.

Three things in your text are picked up and turned into links.

- `@name` addresses somebody on this server, `@name@their.server` somebody
  elsewhere. They are told about it, and the post is delivered to them.
- `#word` files the post under that tag, so it shows up for anybody following
  the tag. Case does not matter: `#Elixir` and `#elixir` are the same tag.
- `:shortcode:` becomes a custom emoji if this server has one by that name. If
  it does not, the word stays as you typed it, which is usually what you meant.

While you type, the box suggests accounts, tags and emoji for the word the
cursor is in. Picking one completes the word.

Underneath the box is a preview. It is produced by the same code that renders
the post for your readers here and on every other server, so what you see is
what goes out.

**Ctrl + Enter** posts without reaching for the mouse.

## How long a post can be

Five hundred characters, counting any content warning you add.

A mention of somebody on another server counts as their name alone. You are
not charged for the length of a domain you did not choose.

A link counts as twenty-three characters however long it really is, so a
tracking URL with two hundred characters of nonsense on the end costs you the
same as a short one. Links are made clickable for you; you do not need to do
anything to them.

## Content warnings

A content warning folds the post behind a line of your own text. Readers see
the warning and choose whether to open it. Any pictures go behind it too: a
post with a warning is marked sensitive, here and on every server it reaches,
so nothing you warned about is showing before somebody decides to look.

Switching the warning off before posting drops what you typed into it. A
warning you decided against does not quietly stay on the post.

## Who can see it, and who can quote it

Four audiences:

| Audience | Who sees it |
| --- | --- |
| Public | Anyone, and it appears in public timelines |
| Quiet public | Anyone who looks, but not in public timelines |
| Followers | Only the people who follow you |
| Mentioned people | Only the people you name in it |

Separately from that, you choose who may quote the post: anyone, only people
who follow you, or nobody. Posting in the open is not the same as agreeing to
be carried off under somebody else's commentary, so the two are asked
separately. Only public posts can be quoted at all; for anything
narrower the quote policy never comes up.

## Language

Every post carries the language you wrote it in. Readers use it to filter
timelines, so setting it right is a courtesy to people who follow you for one
language and not another.

## Replying

Replying fills the box with the author's handle and everybody else already in
the thread, so your reply reaches the people having the conversation. Any of
them can be taken off with the × next to their name before you send it.

A reply never reaches a wider audience than the post it answers. Answering a
followers-only post in public would carry somebody else's words out of the room
they said them in, so the reply stays followers-only.

## Editing

You can edit your own posts. The previous wording is kept and readers can see
that the post was edited and what it said before.

Editing does not change who can see the post. Widening the audience afterwards
would carry it to people you never chose, and narrowing it cannot take back the
copies already delivered, so neither is offered.

Taking somebody's handle out of the text follows the same rule. They stop being
notified and the post stops being carried to them, and it stays readable for
them, because it was already delivered and they may have answered it. Deleting
a message out from under somebody who read it is a stranger thing to do than
leaving it where it is.

## Pictures, video and sound

Attach a file by dropping it on the box, pasting it, or picking it with the
button. Up to four per post. It uploads as soon as you choose it, because the
description, the focal point and a video's still are all things you write while
looking at the picture, and none of them can be written against a file that has
not arrived yet.

**Describe it.** The box under each attachment is the alt text: what somebody
who cannot see the picture gets instead. There is a setting that makes the
composer stop you once if you are about to post a picture without one; pressing
send again posts it anyway.

A description can be corrected after the post has gone out. Editing the post is
what does it, and the correction travels to the servers holding a copy with the
rest of the edit.

**The focal point** is the part of the picture that must survive cropping.
Click the part that matters and the marker moves there. Clients crop
attachments to fit their layouts, and without this they crop to the middle,
which is how a photo of a person becomes a photo of a wall.

**Order** is the order you added them in. **Move earlier** shifts one up.

**A still** can be added to a video or an audio file: a picture shown in its
place before it plays.

While a picture loads, the space it will occupy is filled with roughly its own
colour rather than white, so a timeline does not flash and jump as images
arrive.

## Drafts

The box saves what you have written a couple of seconds after you stop typing,
so closing the tab does not lose it. It saves the whole box: the words, the
content warning, the audience, the language and any poll.

Your drafts are listed under the box. **Open** puts one back in, **Discard**
forgets it. Sending a draft removes it from the list, because it is a post now.

Writing more into a draft updates the same one rather than making another, so a
paragraph is one draft and not two hundred.

You can keep fifty drafts. Past that, the box keeps saving the one you are
writing but will not start a new one until you discard something. It never
deletes a draft to make room.

## Scheduling

A post can be written now and published later. **Schedule** turns the send
button into a time picker. The time is read in your own timezone, and it has to
be at least five minutes away: scheduling is a queue rather than a timer, and a
post due in ten seconds would go out late often enough to look broken. If you
want it out now, post it now.

A scheduled post is not a post yet. It does not appear on your profile, nobody
can see it, and nothing is sent anywhere until its time comes.

Posts waiting to go out are listed under the box, with the time each is due.
**Call off** cancels one. **Open** puts it back in the box, which cancels the
old one: a scheduled post is the request that made it, so changing one is
writing it again, and leaving both would send the post twice.

You can have 300 posts waiting in total and 25 on any one day.

A scheduled post keeps everything it was written with, including its audience,
its language, its quote policy, its pictures and its poll. A poll's clock starts when the post
goes out rather than when you wrote it, so a one-day poll scheduled for next
week runs for a day next week.

If a scheduled post can no longer be published when its time arrives — because
the post it was replying to has been deleted, say — it is dropped rather than
retried. The alternative is a queue that tries and fails every minute forever.

## Polls

A poll offers between two and four options. Options cannot repeat: a poll with
the same answer twice cannot be read, because nobody can tell which one they
picked.

You cannot vote in your own poll.

A poll that takes more than one answer shows two numbers, because they are not
the same thing: **votes** counts answers and **people** counts the people who
gave them, so three people picking two options each is six votes. A poll that
takes one answer shows only the votes, since the second number would be the
first written twice. How you voted is shown to you and to nobody else.

## Boosting

You can boost anybody's public or unlisted post, and any of your own whatever
its audience.

You cannot boost somebody else's followers-only or direct post. Being able to
read it is not the same as being able to carry it to your own followers, who
are not the audience its author chose.

## Pinning

You can pin your own public posts to the top of your profile, up to five at a
time. Followers-only posts cannot be pinned, because everybody who visits a
profile sees what is pinned there, and pinning one would publish it to people
it was never sent to.

Boosts cannot be pinned. The post belongs to somebody else.

## Muting a thread

Muting a conversation stops it reaching you, including the replies nobody has
written yet — which is the point, and why it is the thread that is muted rather
than the post you were looking at.

It is your decision alone. Nobody else in the thread is affected and nobody is
told.

## Direct messages

A post addressed to "only the people you name" is a direct message. It reaches
the people named in it and nobody else: not your followers, not the public
timelines, not somebody browsing your profile.

Your side of it lives in **Messages**, in the navigation, rather than in a
timeline. One line per conversation, newest first, with the last message shown.
Twenty messages back and forth is one conversation you are having, not twenty
things to read. A count next to the link says how many are waiting.

A conversation with a different set of people in it is a different line, even
when it grew out of the same thread. To you they are two conversations, so they
are two lines.

Opening one marks it read and shows the thread on the last message's page.
**Mark unread** puts it back, and is yours alone: neither marking changes
anything for anybody else in the thread. **Remove** takes it out of your inbox
only; nobody else loses anything, and a later message brings it back.

Muting is not on this screen and does not need to be: it is the thread that is
muted, from the **…** menu on any post in it. A direct message also arrives as
a [notification](notifications.md), which is what tells you it is there — the
inbox is where you read it.

## Where a post lives

Every post has a page of its own at `/@you/<id>`, and your profile is at
`/@you`. Somebody on another server is at `/@them@their.server`.

Those pages are built by the server, so a link you paste anywhere shows a real
preview, and somebody who is not signed in can read it. A content warning is
what the preview shows rather than the words behind it: a preview that unfolded
the warning would defeat it.

The page shows the whole conversation, what came before the post and what came
after, with the post the link was for marked. Replies that only exist on
another server are not there until somebody asks: the button fetches them, and
it is only offered to people who are signed in, because it makes this server go
and talk to another one.

## Pictures, video and sound

An ordinary photo finishes while you are still typing; anything larger is
worked on in the background and your app waits for it. Large pictures are
scaled down and everything gets a small version for timelines.

Metadata is stripped from pictures on the way in, including where the photo was
taken and on what. Posting a picture is not agreeing to publish your address.
The colour profile is kept, so a wide-gamut photo still looks right.

Videos are converted to a format every browser plays, unless yours already is
one, which is usually the case for something recorded on a phone; then it is
repackaged rather than re-encoded, which is faster and loses nothing. An
animated GIF becomes a short video that plays the same and is a fraction of the
size. Audio is converted to mp3, and cover art embedded in the file becomes the
picture your player shows.

If a file cannot be processed your app is told, rather than being left waiting
for something that is never coming.

## Links

Post a link and it turns into a preview: a title, a description and usually a
picture. Only the first link in a post gets one, and it appears a moment after
you post rather than while you are waiting, because it means asking the other
site for the details.

Where a site publishes an embed for its videos, the player is shown instead.
Where it publishes nothing at all, you get its title, which is still better
than a bare address.

A site can name the fediverse account of whoever wrote the piece. Where that
account is one this server can see, the preview shows it and you can follow
them from there.

## Reading a post in another language

Where this server has translation set up, a post written in a language other
than yours carries a translate button. Pressing it replaces the text, the
content warning, any poll options and the picture descriptions with a
translation, and says underneath who translated it. Reload the page for the
original.

Only public posts can be translated: it means handing the words to another
company, which is not something to do with a post somebody addressed to their
followers. Custom emoji are left alone rather than translated into something
that no longer works.

## Deleting

Deleting a post hands its text back, which is what "delete and redraft" in your
app is doing: it deletes the post and puts what you wrote back in the compose
box.

Other servers are asked to delete their copy. Whether they do is up to them,
and a server that was offline when you deleted may not hear about it at all.

Deleting a direct message takes it out of the **Messages** inbox of everybody
it was between, on this server. If it was the only message in that
conversation, the line goes with it; if there were others, the one before it
becomes the last one shown.
