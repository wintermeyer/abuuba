# Configuration

Two kinds of setting, and which kind a thing is tells you who owns it.

**Environment variables** are read once, when the server boots, by
`config/runtime.exs`. They are the things a machine needs to exist at all:
where the database is, what the server calls itself, how mail leaves. Changing
one is a restart.

**Instance settings** live in the database and are changed in the admin area
while the server runs. They are the things a moderator decides: whether
registrations are open, what the server is called, whether trends are shown.

If you are looking for a switch and it is not in one list, it is in the other.

## Environment variables

Everything below is read by `config/runtime.exs`. Anything not in this file is
not read by anything, whatever some other server's documentation calls it.

### Required

The server refuses to start without these, with a message that says what to
set. That is deliberate: each of them has a wrong default that fails quietly
later rather than loudly now.

| Variable | What it is |
| --- | --- |
| `DATABASE_URL` | `ecto://user:password@host/database` |
| `SECRET_KEY_BASE` | Signs sessions and tokens. 64+ random bytes. |
| `CLOAK_KEY` | Encrypts private keys and OTP secrets. Base64, exactly 32 bytes decoded. **Not recoverable if lost.** |
| `MEDIA_ROOT` | Where uploads are written. Not required when `MEDIA_STORAGE=s3`. |
| `MAIL_FROM` | The address confirmations and resets are sent from. |
| `SMTP_RELAY` | The mail server to hand outgoing mail to. Not required when `MAIL_ADAPTER` is something other than `smtp`. |

### The server's own name

| Variable | Default | What it does |
| --- | --- | --- |
| `PHX_HOST` | `example.com` | The hostname this instance is reachable at |
| `LOCAL_DOMAIN` | `PHX_HOST` | The domain in account addresses and in every id this server publishes |
| `URI_SCHEME` | `https` | The scheme those ids are written with |
| `PORT` | `4000` | The port to listen on |
| `PHX_SERVER` | unset | Set it to start the web server; the container image already does |

`LOCAL_DOMAIN` exists for the case where the two differ: a server reachable at
`abuuba.example.com` handing out `@name@example.com` addresses. Most deployments
leave it alone.

**Neither can be changed on a running instance.** Both go into every
identifier this server has already published, and other servers have stored
those. Changing one orphans everything federated so far.

### Database

| Variable | Default | What it does |
| --- | --- | --- |
| `POOL_SIZE` | `10` | Connections per abuuba process. Room for it has to exist in Postgres's `max_connections`. |
| `ECTO_IPV6` | unset | `true` to connect to Postgres over IPv6 |

### Mail

| Variable | Default | What it does |
| --- | --- | --- |
| `MAIL_ADAPTER` | `smtp` | `smtp`, `mailgun`, or `local` |
| `MAIL_FROM` | — | Required. The sender address. |
| `SMTP_RELAY` | — | Required for `smtp`. The relay host. |
| `SMTP_PORT` | `587` | |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | unset | Omit both for a relay that does not authenticate |
| `MAILGUN_API_KEY`, `MAILGUN_DOMAIN` | — | Required for `mailgun` |

`local` delivers nothing: it keeps mail in memory for a developer to look at.
It exists so that somebody trying the software out is not blocked on a relay,
and a server running in that mode signs nobody up unless an admin approves
each account by hand.

### Media

| Variable | Default | What it does |
| --- | --- | --- |
| `MEDIA_STORAGE` | local disk | `s3` to store uploads on an S3-compatible service |
| `MEDIA_ROOT` | — | Required for local disk. The directory uploads go in. |
| `MEDIA_ALIAS_HOST` | unset | A CDN host to send clients to instead. Works with either backend. |
| `S3_BUCKET` | — | Required for `s3` |
| `S3_REGION` | `us-east-1` | |
| `S3_ENDPOINT` | unset | For everything that speaks the protocol without being AWS |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | — | Required for `s3` |

More on the trade-off between the two in [where media lives](media-storage.md).

### Optional services

| Variable | What it does |
| --- | --- |
| `TRANSLATION_PROVIDER` | `deepl` or `libretranslate`; unset means posts are not translatable |
| `DEEPL_API_KEY`, `DEEPL_HOST` | For `deepl`. The host is for the free-tier endpoint. |
| `LIBRETRANSLATE_ENDPOINT`, `LIBRETRANSLATE_API_KEY` | For `libretranslate` |
| `HCAPTCHA_SITE_KEY`, `HCAPTCHA_SECRET` | Both, or the sign-up puzzle stays off |
| `DNS_CLUSTER_QUERY` | A DNS name whose records are the other nodes, for running more than one |

See [translating posts](translation.md) and
[keeping abuse out at the door](signup-blocks.md) for what those two do.

### Two switches for a closed test network

Both are off unless the environment says `true`, and neither belongs on a
server anybody else can reach. They are documented here so that an operator
can confirm they are off, which is the only reason to know about them.

| Variable | What it does |
| --- | --- |
| `ALLOW_PRIVATE_FEDERATION_ADDRESSES` | `true` turns off the check that refuses to fetch anything on a private network |
| `ALLOW_INSECURE_FEDERATION` | `true` lets a federation fetch go over plain HTTP |

The first one is the SSRF guard. A federation fetch is aimed by whatever a
stranger's document said, so following one into `127.0.0.1` or
`169.254.169.254` hands a stranger the inside of the machine — the cloud
metadata service on that second address is how credentials get read out of a
server. The interop suite turns it off because a Docker bridge network is
entirely private and nothing else about the suite would work; that is the case
it exists for.

The second lets a fetch go over plain HTTP, which anything between here and
there can read and rewrite. What arrives is then acted on as though the server
named in it had said it.

Both are read from the environment at boot and from nowhere else. Nothing in
the admin area, the API or the database can turn either on, deliberately: a
switch that disables a security check must not be reachable by anybody who has
found their way into the running server.

## Instance settings

Changed in the admin area, effective immediately, no restart.

| Setting | Default | What it does |
| --- | --- | --- |
| Registration mode | **approved** | `open` takes anyone, `approved` queues them for a moderator, `closed` takes nobody |
| Site title | `abuuba` | The name in page titles and in the mail this server sends |
| Limited federation | off | On, this server only talks to domains on an allow list |
| Trendable by default | off | On, something can trend without a moderator having approved it |
| Email updates | off | On, each person may collect email addresses for updates |
| Asking for money | empty | A message, a link and a button label that clients show to people signed in here |

Two of those defaults are deliberately cautious. **Approved** rather than open,
because an open server left unattended fills with spam registrations within
days and the admin who forgot is the one who finds out; there is also a
scheduled job that closes registrations on a server nobody is moderating.
**Trendable off**, because a trending list nobody has reviewed is whatever an
anonymous crowd pushed hardest, and the front page is the worst place to
discover that.

### Email updates

Off by default, and it takes two switches to turn on: this one, and then each
person separately under **Settings → Privacy**. Somebody who does not want an
account here can give an address instead and read what one person writes.

Nothing is ever sent to an address that has not confirmed. Giving an address
produces one message asking whether the claim is true, and repeating the
submission does not repeat the message: an unconfirmed address gets at most one
a day, and an address that has already confirmed gets none at all. That, and
the unsubscribe link every message carries, is what keeps the form from being a
way to mail strangers with this server's reputation on it. Unconfirmed rows are
deleted after a week by `Abuuba.EmailSubscriptions.PurgeWorker`, because an
address that never answered did not want the mail.

Writing to a list is bounded too: four messages per account per day, counted
the same way posting and following are. Every message is recorded in
`email_subscription_messages` with its subject, body, when it went out and how
many addresses it reached, so an admin fielding a complaint can see exactly
what was sent in somebody's name. A list is mailed a page at a time by
`Abuuba.EmailSubscriptions.BroadcastWorker`, with the cursor kept on the message
row: a job that dies repeats at most one page rather than mailing the whole
list a second time.

Subscribing happens from the profile page as well as over the API, and both
spend the same per-address budget, so the form is not a way around the
endpoint's limit.

The API endpoint is open to anybody, deliberately: the person subscribing is
usually not a member. It is throttled per client address (the `email_subscription`
bucket, five an hour), the confirmation is queued rather than sent inside the
request so that response time gives nothing away, and an account that does not
take subscribers answers `404` whichever of the reasons applies, so that nobody
can use it to find out which accounts here are worth probing further.

What exists today is the list: the endpoint, the confirmation, the unsubscribe
page, and the count on each person's privacy page. There is no profile form and
nothing yet writes to the people on the list.

### Asking for money

Write a message, an `http` or `https` link, and optionally what the button
should say; clients show it to people signed in here. Leave the message empty
to take it down. A link that is not `http` or `https` is refused rather than
stored, because whatever is written here is rendered as a link in every client
on this server.

The campaign's id is derived from what you wrote, so rewriting the appeal shows
it again to people who dismissed the old one, and reading it twice does not.
This server never handles the money; the button leads off it.

The reference implementation fetches this from a service its own project runs,
which decides for every server what its users are asked to fund. abuuba reads it
from your settings instead, so nothing is asked of your users that you did not
write, and no third party learns you are running a server by being asked.

### Your own CSS

A text field in the settings, served at `/custom.css` from this server and
linked from every page after the server's own stylesheet — so a rule of yours
wins without needing `!important` on every line. It goes out exactly as typed:
styling a server is the one place where "we know better than you what you
meant" is wrong, and anybody who can write here can already change every page.

Cached for a minute rather than a day, because an admin adjusting a colour
should see it on the next reload.

### What else this server answers

`GET /manifest` is what lets somebody add the server to a phone's home screen
and have it open as an application. It is built from your settings, so renaming
the server does not leave the old name on everybody's home screen, and it names
`/share` as where a share from the operating system lands.

`GET /api/v1/instance/activity` is twelve weeks of this server's pulse --
posts written, people signing in, people joining -- which the
server-comparison crawlers chart. Aggregates only: the sign-in numbers are
frozen per week as bare counts, so the graph outlives the 30-day sweep that
deletes the sign-in records themselves, and nothing about who was here or
from where is kept beyond that sweep. In limited federation mode the endpoint
answers 404 rather than publishing vital signs to strangers.

`GET|POST /oauth/userinfo` and `/.well-known/openid-configuration` are for
single-sign-on clients, some of which will not talk to a server that does not
answer them. `userinfo` returns the same account a client already gets from
`verify_credentials`, under the field names those libraries expect; `sub` is
the account id and never the username, because a name can be changed and a
subject identifier may not.

`/unsubscribe/:token` is one click from inside a message. The token is a signed
statement of which account and which kind of mail, generated when the message
is written and never stored — no table to grow, no row to leak. It does not
expire, on purpose: somebody finding a year-old message and wanting the mail to
stop is exactly who it is for, and the alternative is that they mark it as
spam, which costs your server's reputation for everybody on it. Mail about
somebody's own account, such as a password reset, is not covered and never
stops.

### Checking for updates

Off unless you turn it on. When on, this server asks the releases endpoint
whether there is a newer abuuba, at most once every six hours.

What that tells the other end is what any web request tells anybody: this
server's address, a user agent, and that somebody asked. Nothing about the
accounts here, their number or their posts is sent, and there is nowhere in the
request for it to go — it is a GET with no query and no body. It is still a
third party learning that this server exists, which is why it is a decision
rather than a default.

### Follow suggestions

**Administration → Suggestions** lists who this server puts in front of a
newcomer, ranked the way the suggestions themselves are. Taking somebody out is
not a block and not a silence: their account carries on exactly as before and
nobody is told. It is for the account you would rather not lead with — a bot
with a thousand followers, somebody who asked not to be suggested — where a
moderation action would be out of all proportion.

Accounts you have taken out are shown first, since an admin opening that screen
is usually there to undo something.

### Email subscriptions

**Administration → Email subscriptions** shows how many confirmed subscribers
each account here has. Confirmed only: an unconfirmed address is a claim
somebody typed into a form, and counting it would tell you this server is
sending mail it is not.

The rest of the admin area — rules, terms, announcements, invites, roles,
domain blocks — is documented on its own pages, listed in the
[admin guide index](README.md).
