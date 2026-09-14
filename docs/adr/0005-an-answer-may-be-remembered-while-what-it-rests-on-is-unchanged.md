<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# 0005. An answer may be remembered while everything it rests on is unchanged

**Status:** accepted.

## Context

The whole cost of a mutation run is the mutants it executes, so the largest saving available
is not executing the ones whose answer cannot have changed.

The way an outcome cache goes wrong is silent. `survived` comes back for a mutant a test now
catches; the score goes up while the tests got no better; nobody looks at it again. So the
key has to name everything that could change the answer and nothing that could not — the
first makes it unsound, the second makes it useless.

## Decision

An answer is filed under a digest of three things.

**The mutant.** Already content-addressed: its identity covers the file's digest, the span,
the bytes on either side of the edit, and the versioned rule that made it
([0001](0001-mutants-are-anchored-to-byte-spans.md)). Edit the line and it is a different
mutant with a different name.

**The build of this tool.** A rule may come to mean something new, or a verdict may be
decided differently, and an answer from one build is not evidence about another.

**The behaviour of every file the tests that reach it execute.** This is the part that makes
the cache worth having, and it is observed rather than estimated: the probe records which
guards each test evaluated, and every guard is in a file, so the files a test runs are known.
Change one corner of a package and only the mutants whose tests go near it are measured
again.

What cannot be observed is part of every key rather than left out. A file with no mutants has
no guards, so nothing can be seen about it — and **every test file is of that kind**. What a
test concludes rests on the test as much as on the code, so the digests of those files are in
every mutant's key: changing any of them asks every question again. A cache that watched only
the files it could mutate would answer `survived` for a mutant somebody had just written a
test for.

Only three outcomes are stored: `killed`, `survived`, and a timeout confirmed by a serial
retry. A mutant that errored, that ran out of time once on a busy laptop, that somebody
interrupted, or that the compiler refused is a statement about the afternoon it happened in,
and keeping those would make a bad afternoon permanent.

## Consequences

It fails closed at every step. A mutant whose dependencies are not fully known is asked
again; a cache file it cannot read is no cache; a file whose digest is missing makes the
mutants that rest on it uncacheable rather than cached against a dependency set that quietly
omits something. Being slow is recoverable and being wrong is not.

The remembered rows are indistinguishable from fresh ones — same order, same coverage, same
everything a reader can see — because a report that changed shape because a cache was warm
would be a different report about the same run. The one visible difference is the `cached`
column, which says how much of a report was measured this afternoon.

### The boundary, written down rather than discovered later

This assumes that a test which executes a file evaluates a guard in it. Under the default
profile nearly every executable statement is a mutation site, so a test that runs a function
runs a guard. The exception is a region where every statement was suppressed — a function
that only logs, say. A test that executed such a region of a changed file *and nothing else
of that file* would keep an answer it should have asked again.

That is the edge of what the probe can see. Closing it needs observation that does not depend
on mutants existing — a probe at every function entry, which is a later step with its own
evidence. Until then `--cache off` is the answer for anybody who needs the guarantee, and
this paragraph is the answer for anybody who needs to know.
