<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# 0008. A guard wraps an expression, and a declaration cannot be guarded at all

**Status:** accepted. The statement form the plan reserved is not built, and this records
why building it would not have helped the case it was reserved for.

## Context

[0002](0002-expression-guards-are-the-default-form.md) made the expression ternary the
default form: a mutant is `(awake ? (mutated) : (original))` wrapped around the smallest
expression that contains the edit. The plan kept two other forms in reserve — a statement
guard (`if awake { } else { original }`) for statement-level operators, and a body guard
for whole-function replacement.

A project measuring its own code with `[[mutation.custom]]` rows raised the question
again. Of 290 anchors written by hand across a real package, 117 were expression-shaped
and the rest were not. The one quoted was:

```toml
find    = "let dropped = Array(entries[limit...])"
replace = "let dropped: [T] = []"
```

That is a declaration, not an expression. Wrapped in a ternary it is not Swift, and the
compiler says so — `expected expression in list of expressions` — so the mutant arrives as
a refusal, in a report about a row somebody wrote rather than about their program.

The obvious reading is that the expression form is too narrow and the statement form is
overdue. That reading is wrong, and the reason is worth writing down rather than
rediscovering.

## Decision

**The statement guard is not built, because it cannot express this either.**

A declaration binds a name. `if awake { let dropped: [T] = [] } else { let dropped = ... }`
binds `dropped` inside a scope that ends at the closing brace, so every line after it
stops compiling. There is no arrangement of a guard that replaces a declaration *and*
leaves its bindings visible — not the ternary, not the `if`/`else`, not anything. This is
a property of what a declaration is, not a limitation of the form this tool chose.

What the form actually excludes is narrower than "statements", and worth stating precisely
because the general word is misleading. Measured on this toolchain:

| shape | in a ternary |
| --- | --- |
| `n += 1` | compiles — assignment is an expression in Swift |
| `f(x)` | compiles |
| `try await f()` | compiles |
| `let x = f()` | refused — declaration |
| `return x` | refused — statement |
| `guard … else { … }` | refused — statement |

So assignments, calls and effectful expressions all guard fine. Declarations and
control-flow statements do not, and for declarations no other form would.

**The answer is to anchor on the initialiser.** `Array(entries[limit...])` replaced by
`[]` is an expression of the same type, it guards, and it changes exactly what the row
meant to change. It costs the author nothing but knowing to do it.

**So the work went into saying that.** A refused custom mutant now explains itself: that
the refusal is about the row rather than about their code, that a guard is a ternary and
therefore needs an expression, and what to anchor on instead. A refusal of an ordinary
mutant still says nothing extra, because there is nothing to do about it — the compiler
would not accept that edit there, and that is a fact about the program.

## Consequences

Custom rows that name a declaration are still refused, and are still counted as
rejections. That is the honest outcome: the tool will not silently reinterpret what
somebody wrote as something adjacent, which is how a project ends up measuring a mutant it
did not ask for and cannot find.

The body guard (form B, whole-function replacement) is a different question and is not
settled here. It does not replace a declaration; it prepends a return to a function body,
and nothing about this argument applies to it.

If a statement guard is ever built, it will be for statement-level *operators* — deleting
a call statement, emptying a `defer` body — where the tool chooses the site and can choose
one whose bindings nothing outside it uses. It will not be a way to make arbitrary
hand-written anchors work, and this ADR exists so that nobody builds it expecting that.
