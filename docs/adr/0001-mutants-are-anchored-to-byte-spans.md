<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# 0001. A mutant is anchored to a UTF-8 byte span, never to a syntax node identity

**Status:** accepted.

## Context

Discovery parses a file and decides where a mutant goes. Instrumentation, later and in a
different process, has to find that place again. The two phases need a name for a
location that survives the trip.

`SwiftSyntax` offers `SyntaxIdentifier`, which is the obvious candidate and the wrong one.
Its own documentation says it can be transferred only across trees that are structurally
equivalent: it is an index into one particular parse.

Muter used it anyway. `SchemataMutationMapping` keyed every mutation site on the node's
identity, and `ApplySchemata` then re-parsed each file — a change made to stop large
codebases from exhausting memory — and walked the fresh tree. The re-parsed nodes carried
new identities, not one key matched, and the rewriter inserted **zero** schemata. The
build was clean, the run completed, and roughly four hundred previously-killed mutants
were reported as newly surviving (muter-mutation-testing/muter#307). A second report
(#308) found four further corruption modes from the same area, including mutants that
appeared in the report having never been inserted at all.

Nothing about that failure is loud. The tool did not crash; it produced a number.

## Decision

A mutant's location is a `SourceSpan`: a half-open range of **UTF-8 byte offsets** into
the original file, carried alongside a digest of the bytes it covers. `SyntaxIdentifier`
does not appear in shipped code, and `MutantAnchorGateTests` fails the build if it does.

Byte offsets were chosen over line/column pairs because they are the unit
`AbsolutePosition`, `swiftc -dump-ast`'s `range` field and the compiler's diagnostics all
already agree on, so no join needs a conversion.

## Consequences

- A site found by one phase is found identically by every later phase, by a different
  process, after a `swift-syntax` upgrade, and after a round trip through a JSON plan
  file.
- Mutant identity, the outcome cache, deterministic sharding, resume, and SARIF
  `partialFingerprints` all fall out of the same primitive.
- The tree is parsed once per file and the spans are carried forward; nothing depends on
  two parses producing identical trees, because nothing compares trees.
- Splicing works on bytes rather than on a pretty-printed tree, which is what lets
  comments, whitespace, CRLF and — critically — **line numbers** survive untouched, so
  coverage data maps one-to-one onto the original file.
