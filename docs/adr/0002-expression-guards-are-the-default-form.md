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

Measured on Swift 6.3.3, chaining ternary guards whose two branches differ by one operator:

| Guards in one expression | 5 | 10 | 20 | 40 |
| --- | ---: | ---: | ---: | ---: |
| `swiftc -typecheck` | 0.10s | 0.11s | 0.11s | 0.18s |

Nested worst-case shapes measured the same. The solver stays linear because **both
branches have the same type**, which pins the constraint rather than opening it — the
SR-1577 case is literals under overload ambiguity, which is a different shape.

Expression-level guards are therefore the default:

```swift
(__sm(1234) ? (a != b) : (a == b))
```

Statement-level guards (`Form S`) are used only where the mutation *is* a statement —
statement deletion, `defer` and `catch` body removal — and a body guard (`Form B`) prepends
one line on the same physical line as the opening brace for whole-body replacement, so the
original body is not moved by even one line.

A per-expression guard budget stays in the design, and compile validation records
per-file type-check time, so a regression in a future toolchain shows up as a number
rather than as a mysteriously slow run.

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
