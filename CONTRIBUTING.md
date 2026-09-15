<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Contributing

## Getting set up

```console
mise trust
mise install
./scripts/doctor.sh
lefthook install
```

`doctor` is first because most of what goes wrong in a fresh checkout is a missing tool,
and it says so in one line instead of as a confusing build error twenty minutes later.

## How work is done here

**Development is test-driven, without exception.** Write the failing test, run it and
watch it fail, check it fails for the right reason — an assertion rather than a compile
error — then write the least code that makes it pass, then refactor while green.

A test that has never failed has not been shown to work. When you add a gate, prove it
fires: introduce the violation it is meant to catch, watch it fail, then take the
violation away again.

**And then a green test is worth something else: it rules explanations out.** The most
useful test in this repository on one particular day never fired. A run had left orphaned
compiler processes behind, the obvious explanation was a missing kill, and the test that
asserts a grandchild outliving its parent gets killed was green — so the obvious
explanation was wrong, and had to be, before any code was written. The real mechanism was
one level further back: the isolation that makes a trial killable is the same isolation
that stops a signal reaching it from the process that died.

That only works if you can say precisely what a green test covers. A test whose coverage is
vague is green for reasons nobody can enumerate, so it refuses nothing — which is what
makes perturbation the thing that *earns* the constraint rather than a separate practice
from it. Breaking the code is how you find out what a passing test is actually saying, and
only then can its passing rule anything out. Two tests written on that same day passed
against a rule that did nothing, because their subjects were never candidates; only
breaking the rule showed it.

**A survivor is the same instrument pointed at a belief.** It is usually read as a hole in
the tests, and often that is all it is. But a mutant that lives says exactly one thing —
nothing observed this change — and sometimes the reason nothing observed it is that the
thing you believed was doing the work was not doing it. Reported from a real package: a
survivor said "nothing can tell whether these keys were sorted", its author went to write
the missing assertion, and it would not write, because the bytes were stable for a reason
that had nothing to do with the sort. The hole was in a comment, and the tests were merely
where it showed.

**The diagnostic substrate comes before the thing it diagnoses.** A phase ships its own
tracing, its own fake toolchain and its own failure evidence in the same change that
introduces it. "We will add the logging later" is how a tool ends up unable to explain
itself in exactly the run somebody needs explained.

**Prove rather than infer.** Muter assumed its mutants had been spliced into the build and
reported four hundred false regressions when they had not. Anything this tool asserts
about a program must be something it measured.

## The gates

`mise run check` is the whole bar in one command: every static analysis tool over every
file, then the unit tier. `lefthook` runs the fast half before each commit and all of it
before each push, so nothing reaches CI that could have failed locally.

```console
mise run check              # everything
mise run test:unit          # no toolchain, no network, no clock; seconds
mise run test:integration   # drives a real Swift toolchain
mise run analyze            # swiftlint analyze + periphery; needs a compiler log
mise run watch              # the inner loop
```

Some invariants are enforced by gates rather than by review, because they are the kind of
mistake review does not catch. They live in `Tests/RepositoryGateTests` and
`rules/ast-grep`, and each one names the failure it exists to prevent.

## The tiers

A test target's name declares which tier it belongs to, and `TestTierGateTests` enforces
it:

| Suffix | Tier | May use |
| --- | --- | --- |
| `Tests` | unit | pure code and fake toolchains, nothing else |
| `IntegrationTests` | integration | a real Swift toolchain |
| `ToolchainTests` | toolchain | Xcode, a simulator |

The unit tier has to stay in seconds, because that is what makes the inner loop an inner
loop.

## The codebase is English

Source, comments, identifiers, documentation, configuration, and commit messages. The
audience for the repository is whoever reads it next, and they were not in the
conversation it came out of. `ProvenanceGateTests` enforces it across every text file.

## Commits

Conventional Commits, checked by `committed` on the `commit-msg` hook and read by
release automation. Keep the subject imperative, under 72 characters, and unpunctuated.
