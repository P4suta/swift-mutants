<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# 0009. There is no benchmark gate

## Status

Accepted.

## Context

The plan this repository was built from lists a `bench` job: `hyperfine` over the main
paths, run nightly, "so the speed claims are fixed by numbers (regression detection)".

Every other job in that list has been built. This one has not, and the reason is worth
writing down rather than leaving as an absence somebody fills in later.

## Decision

**No job fails because something measured slower than it did yesterday.**

A wall-clock number is a fact about a machine, not about this program. A CI runner is
shared, throttled, and running somebody else's job on the other half of the box; the same
commit measured twice differs by more than most real regressions. A gate on that number
is a gate that goes red for reasons nobody can act on — and the thing people do with such
a gate is raise its threshold until it stops going off, at which point it detects nothing
and still costs a job.

This is the same argument the run itself already makes about mutants. A mutant's deadline
is processor time enforced by the kernel, not elapsed time, *because* a busy machine must
not be able to turn a survivor into a detection. It would be strange to refuse a wall
clock for a verdict about somebody's tests and then accept one for a verdict about our
own.

## What is done instead

Complexity is asserted where it can be, as a property rather than a measurement:

- `Batch.grouping` returns the number of comparisons it made, and a test asserts it grows
  with the work rather than with the square of it. That test fails on an algorithm, not on
  a busy afternoon.
- `Run.jobs` is derived from cores and memory, and is tested against both.
- The compile deadline is derived from the priming build the run already paid for, so the
  number moves with the machine instead of being fixed against it.

Where a figure is genuinely wanted — how long a run took, where the time went — it is
*recorded* rather than gated: `--trace` writes durations, and `trace summary` reads them
back. A person comparing two traces is doing something a threshold cannot do, which is
asking why.

## Consequences

A real slowdown can land without a job going red, and will be noticed by somebody running
the tool rather than by CI. That is the accepted cost. The alternative on offer was a job
that goes red at random, which finds the same slowdowns later and several imaginary ones
first.

If this is ever revisited, the thing to build is not a threshold on seconds. It is a
counter — comparisons, processes started, files read — asserted the way `Batch.grouping`
already is. A count is a property of the program and can be gated honestly.
