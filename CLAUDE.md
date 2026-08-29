# abuuba project rules

Phoenix guidelines live in AGENTS.md. These rules govern how issues are worked.

## Product principles

- **Ease of use is a feature.** Plain-language UI copy, helpful empty states,
  error messages that say what to do next, sensible defaults over configuration.
  When a design trades power for clarity, prefer clarity and note the trade-off
  in the issue. This applies to the admin area exactly as much as to the user UI.
- **Documented for admins and users.** `docs/admin/`, `docs/user/` and
  `docs/deploy.md` are part of the product, indexed from `docs/README.md`. Any
  issue that changes user- or admin-visible behavior updates the affected doc
  pages in the same issue. The user guide is mirrored in German under
  `docs/de/user/` and the mirror is complete: an English user page that changes
  changes its German counterpart in the same commit, and a new English user
  page arrives with its translation. The admin guide and the deployment docs
  are English only, deliberately — they track the code closely enough that a
  translation would be stale between releases, and a wrong German page is worse
  for an operator than a right English one. A page that describes what a screen
  or a command does gets checked against the code before it is written: a
  documented button that does not exist is the most expensive kind of
  documentation bug, because somebody goes looking for it.
- **I18n from the start.** Every user-facing string (UI, flash messages, emails,
  validation errors, seeded defaults) goes through Gettext, never hardcoded.
  English is the default locale; German (`de`) is the built-in second language
  and must stay complete: after `mix gettext.extract --merge`, an issue is not
  done while its strings have empty or fuzzy German msgstrs. Locale plumbing is
  issue #71.

## Working through issues

- GitHub issues are numbered in dependency order: always pick the lowest open
  issue number next, and assign `wintermeyer` before starting. Two ordering
  exceptions: #71 (i18n foundation) comes right after #7, before the first
  user-facing UI in #8; #72 (docs skeleton) before M1 is closed.
- Never copy code, CSS, or assets from the Mastodon repo (`~/GitHub/mastodon`,
  AGPL). Read it for protocol facts and behavior only; abuuba is MIT.
- **Check `git branch --show-current` before the first commit of an issue, not
  after.** Every issue is a `issue-<n>-<slug>` branch merged with `--no-ff`, and
  the branch is created in the same breath as `gh issue edit --add-assignee`. On
  #218 that call was bundled with a long release build instead, the branch was
  never made, and the work landed straight on `main` — recoverable only because
  nothing was pushed yet. One `git branch --show-current` before committing
  costs nothing and catches it while the fix is still free.

## A rule is enforced where somebody was looking, and nowhere else

Two shapes, each found repeatedly, each cheap to sweep for and expensive to
meet in production.

- **A reader's rules live in the timeline queries, and a live event never
  passes through one.** Blocks, mutes, domain blocks, muted threads and the
  boosted author are applied by `Abuuba.Statuses.excluding_hidden/2` — so
  anything that hands a reader a post *directly* has to ask the same question
  itself. It did not: the streaming API delivered accounts on a domain the
  reader had blocked and boosts of accounts they had blocked, and the browser
  timeline showed muted authors as their posts arrived and hid them again on
  reload. `Abuuba.Statuses.hidden_for?/2` is the row-at-a-time twin of that
  query filter and is what a live path must call. The same goes for a setting
  that closes a surface: `timeline_access` was honoured by the API and the
  pages, and not by either streaming transport nor by the hashtag RSS feed —
  three doors serving one timeline, one of them open. **When you add a rule
  about what a reader may see, list every way a post reaches them (REST,
  websocket, SSE, LiveView, RSS, ActivityPub) and answer it in all of them, or
  in one function they all call.**

- **A shared component draws a control on every screen and only some screens
  answer it.** `AbuubaWeb.StatusComponent` raises favourite, boost, bookmark,
  reply, edit, translate and vote. `AbuubaWeb.PostActions` exists because the
  first three were answered by two screens of six and swallowed by a catch-all
  everywhere else; the sweep that created it missed the other four, and vote,
  edit and translate were each still dead on four to five screens. A catch-all
  `handle_event(_event, _params, socket)` is what makes this silent — no
  error, no write, no redraw. **Sweep it mechanically rather than by eye:**

      grep -rhoE 'phx-(click|submit)="[a-z_]+"' lib/abuuba_web/components/*.ex \
        | grep -oE '"[a-z_]+"' | tr -d '"' | sort -u

  then check each event against every LiveView that renders the component. New
  work on a shared component adds its event to `PostActions` and to every
  screen, or it is dead on arrival somewhere. And a control that genuinely
  cannot work on a screen should not be drawn there — the logged-out front page
  passes `interactive: false`, which suppressed the action bar and not the poll
  form, so a visitor got a vote button on the one page with no handlers at all.

## Elixir gotchas that have already cost time

- **A test that measures time must warm the path first and take a median.** A
  single `:timer.tc` pair makes the first call pay for module loading, JIT
  warm-up and a cold database connection; the constant-time sign-in test read
  that as a 60x difference and failed on CI while passing locally, where the
  modules were already warm. Warm both branches, measure an odd number of
  runs, compare medians.

  **And an A/B comparison must control the time between setup and
  measurement.** After a bulk write, Postgres keeps working in the background
  (autovacuum, analyze, checkpoint), so *when* the measurement starts is a
  hidden variable worth real milliseconds. The bench measured a +26%
  "regression" between two abuuba builds that was really the drain-wait: a bug
  made the old build's wait run its full 2400s, handing it 40 rested minutes
  the new build never got — rest alone was 0.5ms of a 5ms request; the true
  code delta was ~+0.8ms of priced feature cost (new queries, wider rows,
  bigger payloads), not a defect. Before believing an A/B result, ask what the harness
  did differently around the measurement, especially anything that changes
  elapsed time (timeouts, retries, waits); the fix is to force a deterministic
  state (`VACUUM (ANALYZE)`, `CHECKPOINT`) on both sides, which run.sh now
  does. And when both A and B were run by the same harness on the same host, a
  *control that did not change* (Mastodon's container here) separates host
  drift from code drift for free.


- **Never give an account fixture a fixed username in an `async: true` test
  unless the test needs that exact name.** `accounts` has a unique index on
  `(username, domain)`, so two concurrent test transactions inserting the same
  names in opposite orders block on the same index entries and Postgres kills
  one with a deadlock. It surfaces as `40P01` in a test that looks unrelated
  and does not reproduce when the file is run alone, which is an hour of
  chasing production code that was never at fault. Use the fixture's unique
  default, and only name an account when an assertion reads the name.

- **A check added to many endpoints at once is judged by diffing every route's
  behaviour, not by a green suite.** The scope sweep (#190) passed 3,404 tests
  while it had turned four public endpoints into 401s, given `authorize` a
  requirement for a mute scope through a stray second `when` clause (Elixir
  parses `guard when guard` as OR, so it reads as one declaration and is two),
  and left the reads that a token *widens* — a post, a context, a public
  timeline — checking nothing. The suite only covers what somebody already
  thought to write. So: enumerate `AbuubaWeb.Router.__routes__()` and compare each
  route against `main` before committing, and where the invariant is worth
  keeping, leave the enumeration behind as a test rather than as a habit. Two
  specific traps it found. Plug order: a plug that answers the no-token case
  must be declared *after* `RequireUser`, or it replaces the 422 clients expect
  with a 401 that makes an app throw away its token. And "public" is not one
  thing: an endpoint that answers a stranger but answers a token-bearer *more*
  needs the check conditioned on the token, never skipped.

- **A scenario in `test/interop/` establishes its own preconditions and
  restores what it changes from a `trap`, and never relies on the order the
  scenarios happen to run in.** Thirteen of sixteen were failing for reasons
  that had nothing to do with abuuba: four sorted before the scenario that
  created the follow they needed, five sorted after the one that migrates the
  peer's account and takes its follows with it, and `follow_locked` unlocked
  the account on its last line, so every failure left it locked and turned the
  next five follows into requests nobody answered. Each failure named a real
  protocol behaviour ("the post never arrived") and meant nothing of the kind.
  So: call the helper that sets up what you need (`peer_follows_abuuba`), undo
  anything server-wide from a trap rather than at the end, and if a scenario
  genuinely cannot be made independent, add it to `LAST_SCENARIOS` in `run.sh`
  and say why. Before believing a scenario's message, check whether the state
  it needed was ever there.

  **And check it at both ends, because a relationship has two and only one of
  them decides whether anything is sent.** `peer_follows_abuuba` asked the peer
  whether it was following and believed the answer. After `domain_block`
  severed the follows — in both directions, deliberately, and no unblock
  restores a deleted edge — the peer still believed it followed and therefore
  sent no fresh Follow, so the helper went green while abuuba had no follower
  row. That was all of #243: no follower means no delivery job, and a job
  that was never created is invisible. It cost three rounds of instrumentation
  aimed at the wrong server, because the give-up report read `delivery queue:
  [{"completed", 13}]` and that was taken as "we sent everything" when those
  thirteen were somebody else's deliveries. **A queue report can only show the
  jobs that exist; when diagnosing "X never happened", first ask whether the
  work item for X was ever enqueued at all — a healthy quiet queue and nothing
  to send look identical.** The general form: when a precondition is a fact
  two systems each hold separately, assert it on the side that acts on it.

- **Never use `(` as a sigil delimiter for HTML, URLs, or anything else with
  parentheses or `":` in it.** `~s(<img onerror="alert(1)">)` closes early and
  the parser then reports a bogus error many lines further down (a stray
  `"javascript:` became "keyword argument must be followed by space"). Use
  `~s|...|` for markup fixtures, and suspect the nearest paren sigil above
  whenever a syntax error points at a line that is obviously fine.

## Definition of done (every issue, in this order)

1. Tests first, then implementation (see global rules).
2. `mix precommit` green. It includes `mix credo --strict`: fix the code, never
   relax `.credo.exs`, add `# credo:disable` markers, or drop `--strict` to get
   green. Changes to `.credo.exs` need explicit approval from Stefan.
   **`mix precommit` is the last command before `git commit`, always.** Running
   `mix test` after a later edit is not the same check: precommit also runs
   `mix format --check-formatted`, and a stray blank line left by an edit made
   after the last format pass is green locally and red in CI. If anything at
   all changed since the last precommit, run it again.

   **A local precommit only re-emits warnings for files it recompiled.** CI
   builds from nothing and sees every warning; an incremental local build sees
   only the ones it touched, so a warning in a file that was compiled during an
   earlier `mix test <file>` run stays invisible locally and fails CI under
   `test --warnings-as-errors`. That is exactly how an unused `conn` in a new
   test file passed a green local precommit and then failed CI. Before the
   final precommit of an issue, `rm -rf _build/test` so the run is a clean one.

   **And read `mix precommit`'s exit code, never its output.** It prints
   `Result: N passed` and *then* aborts with `ERROR! Test suite aborted after
   successful execution due to warnings while using the --warnings-as-errors
   option`, so a grep for "Result:" or "found no issues" reports success on a
   run that failed. That is how four commits went to `main` with red CI while
   every local check looked green. Run it alone and redirected, and check the
   status immediately:

       mix precommit > /tmp/precommit.log 2>&1
       echo "exit=$?"

   Anything but `exit=0` is a failure however good the log looks. A warning in
   a **test** file counts: ExUnit compiles those on every run, so they fail CI
   even though nothing in `lib/` changed.
3. Run `/simplify` and apply its cleanups.
4. Run `/critique` and fix what it confirms.
5. I18n and docs: new/changed strings extracted and translated to German
   (`mix gettext.extract --merge`, no empty or fuzzy `de` msgstrs); affected
   pages in `docs/admin/`, `docs/user/` and `docs/deploy.md` updated, and every
   changed `docs/user/` page's German mirror in `docs/de/user/` with it.
6. Smoke test in the locally installed Chrome (claude-in-chrome tools): start
   the dev server, exercise the changed feature in the real browser, check the
   browser console for errors. For backend-only issues, exercise the nearest
   user-visible surface (an API endpoint or the page that consumes it).
7. Only then commit (commit-message and footer rules are global).
