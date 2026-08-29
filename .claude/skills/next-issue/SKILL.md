---
name: next-issue
description: Pick the next open GitHub issue in build order and work it to completion per the CLAUDE.md definition of done - one issue per invocation, ending with commit and issue close.
---

# Next issue

Work exactly one GitHub issue from start to finish. One invocation = one issue;
never start a second issue in the same run.

## Steps

1. **Pick.** `gh issue list -R wintermeyer/abuuba --state open --json number,title --limit 100`,
   choose the lowest number, honoring the ordering exceptions in CLAUDE.md
   (#71 right after #7; #72 before M1 closes). Skip issues already assigned to
   someone and in progress elsewhere. If no open issues remain, say so and stop.
2. **Claim.** `gh issue edit <n> --add-assignee wintermeyer` before any work.
3. **Read.** The issue body, linked issues, and the relevant part of the
   Mastodon reference checkout (`~/GitHub/mastodon`) for behavior/protocol facts
   only - never copy its code, CSS, or assets (AGPL; abuuba is MIT).
4. **Branch.** Create `issue-<n>-<slug>` off current `main`.
5. **Work** the full definition of done from CLAUDE.md, in order: tests first,
   implementation, `mix precommit` green (includes `credo --strict`),
   `/simplify`, `/critique`, gettext extract/merge with complete German,
   docs updated, Chrome smoke test.
6. **Ship.** Commit (global message + footer rules), merge or push per the
   repo's current workflow, then close the issue with a short personal note
   per the global close-note rules (`Closes #<n>` in the commit body plus the
   note; never a silent close).
7. **Report** in one short paragraph what shipped and anything deferred.

If blocked by something only Stefan can fix (credentials, permissions, product
decision), leave a comment on the issue describing the blocker, unassign, report,
and stop instead of guessing.
