# When another server stops answering

Servers go away. Some come back after an afternoon, some never do, and this
server has to tell the two apart without an admin watching. It does that by
counting days rather than failures.

## How a server is given up on

Every delivery is retried sixteen times with a growing wait between attempts,
which spreads over roughly a day. Only when all sixteen are exhausted does the
destination get a mark against it, and the mark is a **date**, not a count.

After seven separate dates, this server stops delivering to that domain
altogether. Queued deliveries to it are dropped rather than attempted, which is
the point: a dead host does not fail quickly, it fails by taking the full
timeout on every one of thousands of queued deliveries.

Counting days is what tells a bad afternoon apart from an abandoned instance. A
server that is down for an hour produces thousands of failed deliveries and is
not dead. One that has failed on seven separate days is.

## How it comes back

By making contact. Any successful exchange clears the record: a delivery that
lands, a document this server fetches, an inbound request with a signature that
checks out. There is nothing to reset by hand.

That asymmetry is deliberate. Giving up takes a week of evidence; coming back
takes one message, because a server that is talking to us is a server that is
running, whatever this end's outbound attempts once concluded.

## What it looks like

```elixir
Abuuba.Federation.Availability.unavailable?("example.social")
Abuuba.Federation.Availability.failure_day_count("example.social")
```

A healthy domain has no record at all, so a count of zero means "nothing has
ever gone wrong here", not "the counter was reset".

## What this is not

It is not a block. A domain this server has given up on can still deliver to
us, its users' posts still arrive, and the moment one does the domain is
reachable again. Refusing a server on purpose is a
[domain block](domain-blocks.md), which is a separate thing with its own
controls, and so is stopping delivery to one server by hand: that is a decision
rather than a diagnosis, so an inbound request does not clear it.

It is also not a delivery guarantee. Posts written while a domain was
unreachable are not queued up and sent later once it returns; they were dropped
when the retries ran out. Followers on that server see the account resume from
whenever contact was re-established, with the gap missing. That is how the
fediverse behaves generally, and it is why a server being down for a week is
worth noticing.
