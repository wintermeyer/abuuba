# Other servers

**Administration → Other servers**, which needs `manage_federation`. Every
server this one has heard from, busiest first.

## What the list answers

Domain blocks answer "should we talk to them". This answers the question that
comes first and had nowhere else to be asked: *are* we talking to them, and if
not, why not.

A peer that has quietly stopped accepting deliveries looks exactly like a peer
whose people have gone quiet. An admin who cannot tell those apart finds out
months later that half the network stopped hearing them.

Each row shows the number of accounts and posts this server knows about there,
the software and version if the peer has said, whether deliveries are going out,
and the last error if there was one.

## Delivery

- **Delivering** — nothing is wrong.
- **Treated as down since …** — deliveries failed on enough separate days that
  this server has stopped trying for now. It starts again on its own the moment
  anything from that server arrives, because a peer that is talking to us is a
  peer that is running.
- **Delivery stopped by a moderator** — somebody here decided.

**Stop delivering** is for a server you do not want to send to but do not want
to block: the posts from there still arrive and your people still see them, and
nothing of yours is pushed the other way.

**Forget the failures** clears the recorded bad days and the last error. Use it
for a server that was down and is back — waiting for the count to age out would
leave it treated as unreliable for days after it stopped being so.

## Notes

A line per server, for the other moderators. It never leaves this server, and it
is the place to record why you did something, or that a peer answered a
forwarded report, so the next person does not have to work it out again.

Notes can be written about a server that has never failed. The bookkeeping
behind this list keeps a row only for servers in trouble; writing a note creates
one deliberately.

## Blocking

The button on this list **silences** the server: its posts stop appearing in
public timelines here, and follows across it keep working. That is the quieter
of the two on purpose, because this is one click from a list.

A suspension — which deletes the accounts and everything from them — is a
decision with more to it, and it is made through the domain block API with the
severity spelled out.
