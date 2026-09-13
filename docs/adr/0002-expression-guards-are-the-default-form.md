<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# 0002. Expression-level ternary guards are the default instrumentation form

**Status:** accepted.

## Context

Mutant schemata put every mutant into one build behind a runtime switch. The question is
what shape that switch takes in Swift source.

Muter wraps the enclosing **statement list**:

```swift
if ProcessInfo.processInfo.environment["<id>"] != nil { <mutant> } else { <original> }
```

That shape breaks in four documented ways (muter#308, and Muter's own README): a
`@resultBuilder` body has no statements to wrap and no permitted `return`; a
single-expression body loses its implicit return; a `guard` body must exit; and a `while`
body is not where the expression lives. Muter's answer is to exclude such files, and to
ship a workflow in which the user fixes the resulting compile errors by hand.

The obvious alternative — wrap the smallest expression in a ternary — has a reputation for
being unaffordable. Swift's expression type checker is a constraint solver, and
[SR-1577](https://github.com/apple/swift/issues/44186) records a ternary taking four
seconds where the equivalent `if`/`else` took 5.4 milliseconds.

So the decision turned on a number nobody had measured for *this* shape.

## Decision

Expression-level guards are the default:

```swift
(__sm(1234) ? (a != b) : (a == b))
```

The type-checking objection does not apply to this shape, and the reason is structural
rather than empirical. A ternary's two branches must unify to one type. Here they are the
same expression differing by one operator, so the branches already have that type: the
guard **adds a constraint that is immediately satisfied** rather than an unknown for the
solver to explore. Chaining `n` guards at one site therefore grows the constraint system by
`n` already-determined equalities — linear in the number of guards — rather than opening
`n` independent choices whose combinations the solver would have to search. The SR-1577
case is the opposite shape: numeric *literals* under operator overloading, where each
branch genuinely is an unknown and the search space is what explodes.

That argument, not a stopwatch, is what makes the form affordable. (A run on one machine
chaining forty such guards type-checked in 0.18s, and forty nested ones in the same range,
which is consistent with linear growth — but the timing is corroboration, not the reason:
elapsed time is a property of a machine on a day, while the shape of the constraint system
is a property of the program.)

Statement-level guards (`Form S`) are used only where the mutation *is* a statement —
statement deletion, `defer` and `catch` body removal — and a body guard (`Form B`) prepends
one line on the same physical line as the opening brace for whole-body replacement, so the
original body does not move by even one line.

A per-expression guard budget stays in the design as a bound rather than as a tuning knob,
and compile validation records per-file type-check time so that a *regression* between two
runs of the same tree is visible. Neither decides anything on its own.

## Consequences

- Implicit returns, result builders, closures, `guard` conditions and `let` initialisers
  all keep working. The four corruption modes cannot occur, because statement structure
  is never disturbed.
- `Form D` — Go's declaration form, which needs the declared type spelled out — disappears
  entirely. A ternary sits in an initialiser without naming a type, so the sibling
  projects' `unnameable-decl-type` skip category is very nearly empty here.
- A mutant whose type differs from the original will not compile. That is the desired
  outcome, and compile validation reports it as a rejection carrying the compiler's own
  words rather than dropping it.
