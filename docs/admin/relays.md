# Relays

A relay is a server that forwards every public post it is sent on to everybody
subscribed to it. On a new instance with three accounts and no follows, the
federated timeline is empty until somebody here follows somebody there. A relay
fills it, which is why turning one on is usually the first thing worth doing.

## Adding one

**Administration → Relays**, which needs the `manage_federation` permission.
Paste the relay's **inbox** address — the one its operator publishes — and add
it. It must be `https`.

Adding and turning on are separate steps, so a mistyped address can be
corrected before anything is sent to it.

The same thing from a console, if you prefer one:

```elixir
{:ok, relay} = Abuuba.Federation.Relays.add("https://relay.example/inbox")
```

## Turning it on

```elixir
{:ok, relay} = Abuuba.Federation.Relays.enable(relay)
```

This sends the relay a subscription request and leaves the relay `pending`.
Nothing is forwarded while it is pending: sending posts to a server that has
not yet agreed is how a relay operator ends up with traffic they never asked
for. When the relay agrees, its answer arrives at this server's inbox and the
state becomes `accepted`. Some relays approve automatically within seconds;
others are moderated and can take days.

Check where a relay has got to with:

```elixir
Abuuba.Federation.Relays.list()
```

A relay in state `rejected` turned the request down. That is a decision for its
operator, not something to retry.

## What gets forwarded

Public posts only. Unlisted, followers-only and direct posts never reach a
relay, and that is deliberate rather than an oversight: a relay redistributes
to strangers, which is precisely what a post that is not public has asked this
server not to do. Unlisted counts as not public here, because unlisted means
"keep this out of discovery surfaces" and a relay is the largest discovery
surface there is.

## Turning it off

```elixir
{:ok, relay} = Abuuba.Federation.Relays.disable(relay)   # keeps the entry
{:ok, _relay} = Abuuba.Federation.Relays.remove(relay)   # forgets it entirely
```

Both tell the relay to stop and both stop forwarding here immediately, without
waiting for an answer: a relay that has gone away must not be able to keep this
server subscribed by never replying. If the relay misses the message it may
keep sending posts here for a while. Those are ordinary public posts arriving
at the inbox, and they stop when the relay next notices.

## What a relay costs

Incoming volume, mostly. A busy relay can deliver more posts in an hour than a
small instance's own accounts produce in a month, and all of them are stored
and searched here. Start with one, watch the database grow for a week, and add
another only if the federated timeline still feels thin.

Outgoing volume barely changes: a relay is one more inbox on the list for each
public post, whatever the number of people behind it.

## When a relay stops answering

Nothing to do. A relay is skipped by the same rule as any other server: after
seven separate days on which every delivery attempt was exhausted, this server
stops trying, and it starts again the moment the relay makes contact. The relay
stays in the list as `accepted` throughout, so no subscription is lost while a
relay is having a bad week.

## Reading the list

Each relay shows its state, when something was last sent to it, and the last
error if there was one.

- **Off** — added but not subscribed. Nothing is sent.
- **Waiting for the relay to answer** — the subscription has gone out. Most
  relays answer within seconds; some are moderated and answer when a person
  gets to it.
- **On** — it agreed, and public posts from here go to it.
- **The relay refused** — it said no. Turning it on again re-asks, which is
  worth doing only if you know why it refused.

The last error is there so that a relay failing quietly can be told apart from
a relay nobody has posted to yet. Those look identical otherwise, and what to
do about them is different.

## In the audit log

Adding, turning on, turning off and removing a relay are all recorded with who
did it. A relay is a standing decision to send every public post on this server
to somebody else's machine and to take back whatever it sends, and on a server
with more than one moderator that decision should be findable without asking
around. The log names the relay by its inbox address rather than its id, so the
entry still means something after the relay itself is gone.
