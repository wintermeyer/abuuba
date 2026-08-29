# Profiles

Your page is at `/@you`. Somebody on another server is at `/@them@their.server`.

## The three tabs

**Posts** leaves out replies, so somebody arriving at your profile reads what
you said rather than half of a conversation they cannot see. **Posts and
replies** shows everything. **Media** shows only the posts carrying a picture,
a video or a sound.

Each tab is its own address, so you can link to one and the back button
returns to it.

## What a profile shows

**Pinned posts** sit above the rest on the first tab. You pin your own public
posts, up to five of them; followers-only ones cannot be pinned, because
everybody who visits a profile sees what is pinned there.

**Featured hashtags** are the tags you want people to find you by. Set them in
[settings](settings.md); other servers see them too, and following one opens
that person's posts under that tag rather than the whole server's.

**Featured accounts** are people somebody has picked out as worth following.
You can only feature somebody you follow, and unfollowing or blocking them
takes it down on its own. Nobody is told they have been featured, and it
changes nothing about what either of you can read.

To feature somebody, open their profile and press **Feature on my profile**.
The button appears once you follow them and not before, because the follow is
what the feature rests on. **Stop featuring** takes them back off.

Anyone you have featured appears in a strip on the first tab of your profile,
above your posts, and everybody who visits sees it. It shows up to twenty; an
app reading the API can page through the rest. Turning **Hide who I follow and
who follows me** on in [settings](settings.md) takes the strip down too,
because everybody in it is somebody you follow.

**Email updates** appear at the bottom of the header on a profile whose owner
has turned them on: a box for your address, and then one message asking whether
the address is really yours. No account is needed, and every message after that carries a link
that stops them.

**Fields** are the four name-and-value rows under your bio. A field on somebody
else's profile may carry a **Verified** mark: that is their server saying it
checked the link, and we show what they assert.

Your own fields can earn the mark here too. Put a link to a page you control in
the value, and put a link back to your profile on that page:

```html
<a rel="me" href="https://your.server/@you">Mastodon</a>
```

The server fetches the page shortly after you save, looks for that `rel="me"`,
and marks the field if it finds one. It looks again about once a week, so a
link back that disappears loses the mark, and one you add later picks it up
without you doing anything.

What it will not fetch: plain `http://` addresses, URLs with a username and
password in them, and hosts written in non-ASCII letters. A page that answers
with an error keeps whatever mark it already had, because a site being down for
an afternoon is not evidence that you took your link down. Typing a date into
the field yourself does nothing: the mark is the server's statement, not yours.

**Collections** are lists of accounts somebody has put together — "people I
know who write about gardening" — and handed out as one link. See
[finding things](finding-things.md#collections).

**This account has moved to @somebody** appears across the top of a profile
whose owner has gone elsewhere, with a link to where they went. Without it you
would follow an account that will never post again and never find out why
nothing arrives.

## Acting on somebody

Follow, unfollow, mute and block, and a note only you can read. Blocking also
stops you following them: somebody who blocks and still follows has a timeline
full of the person they just blocked.

Blocking somebody also hides your posts from them, including the direct link to
a post's page.

## Reading from the keyboard

`j` and `k` move between posts on any page that lists them, and the post you
are on is the one your browser has focused, so a screen reader announces it and
the page scrolls to it. `Enter` opens it, `f` favourites, `b` boosts and `r`
replies. `?` lists every shortcut.
