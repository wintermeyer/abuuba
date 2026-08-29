# Contributing to abuuba

Thanks for wanting to help. Please read the first section before you write any
code. The rest is ordinary project housekeeping.

## The clean-room rule

abuuba is MIT licensed. Mastodon is licensed under the AGPL-3.0. Those two are
not compatible in the direction that matters here: a single file copied out of
Mastodon would drag the AGPL over this project and change what everyone else is
allowed to do with it. So the rule is absolute, and it has no exceptions for
"just this small helper".

**You may read Mastodon to learn how things behave.** You have to, really.
Federation is defined as much by what the reference implementation does as by
any specification, and getting the client API right means matching its quirks
rather than its documentation. Facts are not copyrightable, and facts are what
we are after:

* wire formats and JSON field names
* HTTP status codes, header names, pagination semantics
* the order of operations in a handshake, and what a peer expects to receive
* known bugs that other servers now depend on

Where a behaviour of ours is specific enough that somebody will one day ask
where it came from, record the answer beside the code. The paged `replies`
collection is the worked example: `Abuuba.Federation.Serializer` cites the
published protocol documentation for the five inline replies, and
`test/support/data/mastodon_replies_collection.json` holds a `replies` object
captured off the wire, so an audit can see the source was the network rather
than the implementation without taking anybody's word for it.

**You may never copy anything out of it.** Not source code in any language, not
CSS, not images, icons, fonts or sounds, not locale files, not migrations, not
comments. This covers the obvious verbatim paste and also the things people talk
themselves into: renaming the variables, reformatting it, or translating a Ruby
method line by line into Elixir. If you looked at Mastodon's implementation of a
feature, close the file before you write ours, and write it from your
understanding of what it does.

The same applies to anything a coding assistant hands you. Models trained on
public repositories can reproduce AGPL code from memory without saying so, and
you are the one committing it. Read what you are about to commit.

There is a test that fails if an AGPL notice turns up anywhere in the tracked
tree (`test/abuuba/project_docs_test.exs`). Treat it as a tripwire for the
careless case, not as proof that you stayed clean. It would not have caught a
copy from Mastodon in any case: its source files carry no per-file licence
header, so there is nothing for the test to find.

## Working on an issue

Issues are numbered in dependency order, so the lowest open number is normally
the right one to pick up next. Two issues are out of line on purpose: #71, the
i18n foundation, comes straight after #7, and #72, the documentation skeleton,
lands before M1 closes. Say in the issue that you are taking it before you
start, so nobody duplicates your work.

Then, in this order:

1. Write the test first, and watch it fail for the right reason.
2. Implement until it passes.
3. `mix precommit` has to be green. It compiles with warnings as errors, checks
   formatting and unused dependencies, runs Credo in strict mode, and runs the
   test suite with warnings as errors too. It reports rather than rewrites, so
   run `mix format` yourself when it complains. Fix the code rather than
   relaxing `.credo.exs`.
4. Every user-facing string goes through Gettext, and the German locale stays
   complete. After `mix gettext.extract --merge`, no empty or fuzzy German
   entries may be left behind. The locale plumbing itself is issue #71, so
   until that lands there is only an English catalogue to extract into.
5. Update the affected pages under `docs/admin/` and `docs/user/`. Behaviour
   that admins or users can see is not finished until it is written down. Issue
   #72 creates those directories.

## Commits and pull requests

Write a short summary line, then a blank line, then a paragraph explaining why
the change was made. What changed is visible in the diff; the reasoning is not,
and it is what someone will need in a year. Reference the issue with
`Closes #<n>`.

Keep a pull request to one issue. It makes review possible and it makes reverts
cheap.
