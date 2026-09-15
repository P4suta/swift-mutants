<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# 0006. The Xcode path wakes a mutant through the `.xctestrun`, beside the original

**Status:** accepted for the building blocks. The phases that would let `run` use them are
named at the end and are not built.

## Context

Most Swift is written in Xcode projects, and the SwiftPM path cannot measure one: there is
no `.build/debug.yaml` to read a module's `swiftc` argv out of, and no package manifest to
describe. The plan calls for an Xcode path that keeps the same bargain — instrument once,
build once, run many — and the question is what "run one mutant" means when `xcodebuild` is
the thing doing the running.

Three things were measured on this machine (Xcode 26.6, `xcresulttool` 24757) before any of
it was designed, because every one of them would have been a plausible guess and two of them
would have been wrong.

**An Xcode-built test bundle cannot be launched the way the SwiftPM path launches its own.**
The obvious shortcut is to read the bundle's path out of the `.xctestrun` and start it with
the same helper ([0003](0003-tests-are-launched-through-the-swiftpm-helper.md)), reusing the
scheduler, the event stream and the first-failure stop. Tried: the helper exits zero and
writes no events at all. There is no event stream on this path, so there is nothing to watch
and no first failure to stop at.

**`xcodebuild -list -json` does not print only JSON.** It prints a timestamped note about
run destinations first. A reader that decoded the whole output would fail on every project,
with a message about malformed JSON rather than about the note.

**`xcodebuild` exits non-zero for two unrelated reasons.** A failing test is one, which is
exactly what a killed mutant looks like; a project that will not load is the other, which is
not. The status cannot be the verdict.

## Decision

`xcodebuild build-for-testing` runs once and writes a `.xctestrun`. Every mutant after that
is one `test-without-building` against **a copy of that document with its own variable in
it**, and the verdict comes from the result bundle rather than from the exit status.

**The variable goes into every test target, not the first.** A scheme with three test
targets runs three processes. A variable set on one of them wakes the mutant in a third of
the run, and the other two thirds report a mutant their tests cannot catch.

**The copy lives beside the original, and the directory is not a parameter.** Every path
inside a `.xctestrun` is written relative to `__TESTROOT__`, which Xcode resolves against
the directory the document is in. A copy written to a scratch directory therefore names a
bundle that is not there — and `test-without-building` then runs no tests *and exits zero*.
A run built on that reports every mutant surviving, silently, for an hour, which is the
worst answer this tool can give. `Xctestrun.write(named:)` takes no directory because there
is no other right answer.

That was found by an integration test that got an empty result bundle back. Perturbing the
fix fired nothing at first, because the unit fixture had been written straight into the
temporary directory — the very place the perturbation redirected to. The fixture now gets a
directory of its own.

**The documents are read as property lists and as JSON, never as text.** A real `.xctestrun`
holds paths with spaces, arrays, nested dictionaries and a format version; a result bundle
is a directory whose layout Xcode owns and changes, and `xcresulttool` is the only thing
promised to keep working. A format version this tool does not know is refused rather than
guessed at, because waking a mutant in a document it had misread is an hour of answers about
a program with nothing awake.

**Reading the result bundle fails closed at every step.** A bundle-level `Failed` is not a
test — counting one would report a killer nobody can go and look at. A verdict that is not
`Passed` or `Failed` establishes nothing, because reading `Skipped` as a pass is how a
mutant nothing ran against comes back a survivor. A bundle that cannot be read is an error
rather than a suite in which nothing failed.

**The project file is never parsed.** A `.pbxproj` is a format Xcode owns, and this needs
nothing from it: the runtime that wakes a mutant lives inside the file it mutates, so there
is no target membership to work out ([0002](0002-expression-guards-are-the-default-form.md)).

## Consequences

The per-mutant cost is higher than on the SwiftPM path, and that is a fact about `xcodebuild`
rather than a choice. There is no first-failure stop, so a mutant costs a whole filtered
suite instead of the time to its first failing assertion. Coverage narrowing still applies —
`-only-testing:` takes the same list — so the saving that matters most is kept.

### What is not built

`run` cannot yet use any of this, and saying so is the point of writing it down.

**Validation has no Xcode equivalent.** The SwiftPM path asks each module separately using
SwiftPM's own plan ([0004](0004-validation-asks-each-module-separately.md)), which reads
`.build/debug.yaml`. An Xcode project has no such manifest. Without validation the
instrumented tree's first type-incompatible mutant fails the build and the run dies, so this
is a prerequisite rather than a refinement: it needs `xcodebuild` to compile the instrumented
tree and its diagnostics attributed by byte span, which the existing attribution can do once
something hands it the output.

**Execution and probing share one seam, and this part is done.** `MutantHost` is that
seam and has two conformances: `Trial` on the SwiftPM path and `XcodeHost` here. The
scheduler and the prober reach both through it, and neither knows which it has. The
paragraph that stood here said the change was deliberately not made because a protocol with
one conformance is a protocol nobody has checked the shape of; it has two now, and the
shape held — the only thing the second conformance changed was `probe`, which returns how
long it took rather than a bare yes, because the SwiftPM path can measure that and this one
cannot.

That asymmetry is itself worth recording. A per-mutant deadline is split into what a trial
costs before it runs any test and what its tests cost, and the first number comes from the
probe phase. This path has no supervised process of its own to have measured one, so it
reports that a probe finished and says nothing about its cost — and a deadline derived from
nothing falls back to the floor, which is the direction to be wrong in.

**One test bundle per test target is a SwiftPM problem and not this one.** SwiftPM's build
system builds one bundle per test target, so the scheduler runs the ones a mutant's tests
live in. An Xcode project names every test target in one `.xctestrun`, and `-only-testing:`
narrows within it, so nothing here has to be divided.

**Simulator destinations are untried.** Everything above was measured against
`platform=macOS`. A simulator adds a device pool and a boot to manage, and claiming it works
without having run it would be the kind of assumption the rest of this record exists to
avoid.
