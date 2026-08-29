# Webhooks

This server posts to a URL of yours when something happens that a moderator
would want to know about. What is usually listening is a moderation tool, an
alert, or a spreadsheet.

**Administration → Webhooks**, which needs the `manage_webhooks` permission.

## The events

| Event | Sent when |
| --- | --- |
| `account.created` | somebody signs up |
| `account.approved` | a moderator lets a pending registration in |
| `account.updated` | an account here changes: a profile edit, a picture, a privacy switch, or a moderator acting on it |
| `report.created` | a report arrives |
| `report.updated` | a report is resolved, reopened or reassigned |
| `status.created` | somebody here posts |
| `status.updated` | somebody here edits a post |

Accounts on other servers are deliberately out of `account.updated`. This
server refetches their profiles on a schedule, and an integration watching what
happens *here* does not want a stream of other people's churn.

An event name this server does not send is refused when you save, rather than
quietly dropped. Silently keeping the ones it recognised would leave you
watching for something that will never arrive, with nothing anywhere saying so.

## Added off

A webhook is created turned off and you turn it on, so a URL typed wrong can be
corrected before this server starts posting your reports to it. The address must
be `https`.

## The signature

Every delivery carries `X-Hub-Signature-256`, an HMAC-SHA256 of the exact body
under the webhook's secret, and `X-Abuuba-Event` naming the event. Check the
signature: the URL is not a secret and should not have to be one, so anything
that can reach it can post to it.

Compute the HMAC over the raw bytes you received, not over a re-serialised
copy. A signature checked against a re-encoded body stops matching the day a key
order changes.

The secret is shown when the webhook is created and when you rotate it, and
never again — a secret that stays readable on a page leaks with the first
screenshot of that page. Rotating takes effect immediately, with no grace
period, because rotation exists for a secret somebody believes is out.

## What is in a body

```json
{"event": "status.created", "created_at": "...", "object": {"id": "...", "...": "..."}}
```

Identifiers and addresses, not content. A post's body is somebody's writing, and
a webhook payload ends up in somebody else's logs; a receiver that wants the
words can fetch them with the id.

## Delivery, and the log

Deliveries go through the same outbound layer as everything else this server
fetches, so they inherit its SSRF guards, timeouts and circuit breaker. Failures
are retried with backoff; a `4xx` is not, because the receiver understood and
refused and time does not change that.

Every attempt is recorded — successful ones too — and shown under each webhook.
That log is the point: a webhook that has quietly stopped working looks exactly
like a server where nothing has happened, and an admin who cannot tell those
apart finds out weeks later that the queue they were watching was empty because
the pipe was broken. Rows are kept for seven days.
