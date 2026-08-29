---
name: critique
description: Adversarial review of the current issue's changes - hunt for real bugs, edge cases, security holes, and Mastodon-compat violations, verify each finding, then fix what survives. Run at the end of every issue, after /simplify.
---

# Critique

An adversarial pass over the changes made for the current issue. Where `/simplify`
cleans code up, `/critique` tries to break it. The output is fixes, not a report of
open problems.

## Scope

The diff of the current work: uncommitted changes plus commits on this branch that
are not on `main` (`git diff main...HEAD` and `git status`). Read enough surrounding
code to judge the diff in context, but only findings caused or exposed by the diff
are in scope.

## Hunt

Go through these lenses one by one. For each, actively try to construct a failing
input or sequence, don't just skim for style:

1. **Correctness and edge cases**: nil/empty/missing values, off-by-one in
   pagination and cursors, unicode and grapheme handling, timezone/UTC mixups,
   integer overflow on counters, error tuples that are matched incompletely.
2. **Concurrency**: race conditions on upserts and counters, double delivery of
   Oban jobs (every worker must be idempotent), LiveView assigns raced by
   `handle_info`, processes holding stale data after a PubSub broadcast.
3. **Security**: SSRF through any URL-accepting input, authorization on every new
   route and LiveView event handler, visibility leakage (direct/private/limited
   statuses reachable via API, search, timelines, embeds, boosts), unsanitized
   remote HTML, mass assignment via changeset `cast`.
4. **Mastodon compatibility**: does the change alter the semantics of an existing
   API endpoint (status codes, `Link` pagination, string IDs, error body shape,
   quirks documented in the issue)? Compat is bug-for-bug; improvements never go
   into existing endpoint semantics.
5. **Federation**: host-matching anti-spoofing checks on new inbound paths,
   handlers idempotent and tolerant of out-of-order delivery, outbound JSON
   round-trips against the serializer tests.
6. **Database**: missing indexes for new query shapes, N+1 queries (check
   `Repo.preload` vs. per-row queries), migrations that lock large tables or are
   not safely re-runnable, counter updates that read-modify-write.
7. **Tests**: does every behavior change in the diff have a test that fails
   without it? Are the failure paths tested, not only the happy paths?

## Verify, then fix

For each finding, first confirm it against the actual code (construct the failing
case mentally or as a test); discard anything that does not survive verification.
Fix every confirmed finding as a normal bugfix: regression test first, then the
fix. Only leave a finding unfixed when it is genuinely out of scope or needs a
product decision, and say so explicitly.

Finish by running `mix precommit` and reporting: findings fixed (with one line of
why each was real), findings discarded as false alarms, findings deferred and why.
