<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# 0004. Validation asks each module separately, using SwiftPM's own plan

**Status:** accepted.

## Context

Every mutant is spliced into one tree and the compiler is asked which of them it accepts.
Rejections are attributed by byte span, so one compile should name every refusal — bisection
is the fallback, not the mechanism (see [0002](0002-expression-guards-are-the-default-form.md)).

That worked, and the loop still took nineteen rounds on this package.

### `swift build` cannot report an error in a module whose dependency failed

A round is a build. When a module fails, nothing downstream of it is built, because there is
nothing to build it against. So a round surfaces the refusals of one *layer* of the module
graph and hides everything below. A package twenty layers deep needs twenty builds to find
twenty rejections, each of them a build of the whole package. Measured on this repository,
dogfooding it: nineteen rounds, `686 → 664 → 663 → …`, a handful of refusals at a time.

`-continue-building-after-errors` does not help. It continues within a module and across
independent ones; it cannot conjure a `.swiftmodule` that was never emitted.

### A module can be asked on its own, if something already built its dependencies

Compile one target against the interfaces a pristine build produced, and it answers
regardless of what is wrong with the sources of the modules it imports — because nothing is
reading those sources. Every module can be asked at once, and every one of them answers.

Proved against a real toolchain on a two-target package with both targets broken: one pass
names both files; the build it replaces names only the lower one.

### The arguments must not be guessed

A target compiles with its own search paths, module maps, language mode, upcoming features,
package name and SDK — forty-odd arguments here, and every one a chance to be right on this
package and wrong on somebody else's. SwiftPM has already worked them out and writes them as
an llbuild manifest: for each module, the exact `swiftc` invocation it would run.

### `-typecheck` is not the question a build asks

A whole class of Swift error is found after type checking, while the compiler lowers the
program: `missing return in instance method expected to return`, use before initialisation,
and the rest of the mandatory dataflow passes. `swiftc -typecheck` accepts a function with a
missing return and says nothing.

A `return-replacement` mutant produces exactly that shape, and this package has one.
Validation accepted the tree, the build that followed refused it, and the run died — after
validation had already said the tree was fine, which is the worst place for a tool to be
wrong, because it stops answering instead of answering differently.

`-emit-sil -wmo -o /dev/null` runs those passes and still writes nothing. `-emit-silgen`
does not, which is how the two were told apart.

## Decision

A run builds the package as the user wrote it first. That build proves the package builds at
all — the plainest answer a run can give, and one that costs nothing because the build was
needed anyway — and it produces the compiled interfaces and the plan everything else needs.

Validation then asks each module that holds an instrumented file, separately and at once,
with the arguments SwiftPM wrote, lowered rather than merely type-checked, into `/dev/null`
and into a module cache of its own.

Two rules keep it honest:

- **A file that belongs to no module in the plan sends the whole question back to a real
  build.** A plan that does not describe the tree is exactly the situation where being clever
  starts rejecting mutants at positions nobody reported.
- **The question writes nothing.** No object, no module, no header, no dependency file, no
  index — and a separate clang module cache, because a build and a typecheck that disagree
  about how to spell a path (`/var` and `/private/var` name the same directory on macOS)
  leave one module in it under two names. The compiler refuses that with `module
  '_DarwinFoundation1' is defined in both`, on a stream this tool was not reading: the run
  failed saying only "It said nothing".

## Consequences

The number of compiles stops following the depth of somebody's package and becomes one pass
over its breadth, which is also the shape that parallelises. Dogfooding this package went
from nineteen rounds to three.

The cost is one extra full build in the best case — the pristine build, where before the
first validation round was the only one. In the observed case it replaces eighteen.

The format of the manifest is SwiftPM's own and carries no promise of stability. A manifest
this cannot read is `nil` rather than an error, and the caller builds the whole package each
round: slower, and always correct. Guessing at a shape that has changed is the one outcome
worse than being slow.
