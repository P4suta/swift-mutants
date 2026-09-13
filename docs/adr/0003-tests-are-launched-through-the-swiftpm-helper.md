<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# 0003. Tests are launched through the SwiftPM testing helper, not through `swift test`

**Status:** accepted.

## Context

Mutant schemata build once and run N times. The value of that depends entirely on what
"run once" costs, so the question is what this tool actually executes per mutant.

Three candidates, measured against Swift 6.3.3 / Xcode 26.6 on macOS 26.6 arm64.

### Launching the bundle directly does not work on macOS

SwiftPM builds the test target as `<Pkg>PackageTests.xctest`, and on macOS its executable
is linked with `-Xlinker -bundle`:

```console
$ file .build/arm64-apple-macosx/debug/EvPackageTests.xctest/Contents/MacOS/EvPackageTests
Mach-O 64-bit bundle arm64
$ .../Contents/MacOS/EvPackageTests
zsh: exec format error
```

A Mach-O bundle is loaded, not executed. This is the assumption the plan carried in and it
is wrong on the platform that matters most here.

### `xctest` runs it but swallows the arguments

```console
$ xcrun xctest <bundle> --event-stream-output-path events.jsonl --event-stream-version 6.3
Failure: No test bundle found at path `6.3`.
```

`xctest` treats every argument as a bundle path. There is no way to reach swift-testing's
event stream through it, and the event stream is what the early-kill design rests on.

### `swift test` works, and costs a package description per mutant

`swift test --event-stream-output-path <path> --event-stream-version 6.3` does produce the
stream: SwiftPM forwards unrecognised arguments to the test runner. But `swift test` loads
and evaluates the package manifest first, every time. For N mutants that is Θ(N · package
description), on top of the Θ(N) the runs themselves cost — a term that grows with somebody
else's package and buys nothing.

### What SwiftPM actually runs

Observed while a run was in flight:

```text
<toolchain>/usr/libexec/swift/pm/swiftpm-testing-helper
  --test-bundle-path <bundle>/Contents/MacOS/<Name>
  --event-stream-output-path <path> --event-stream-version 6.3
  <bundle>/Contents/MacOS/<Name>
  --testing-library swift-testing
```

`swiftpm-testing-helper` is a small executable that `dlopen`s the bundle and calls
swift-testing's entry point, forwarding everything else. Invoked directly it needs the
framework search paths SwiftPM sets, or `dlopen` fails on `@rpath/Testing.framework`:

```sh
DYLD_FRAMEWORK_PATH="$(xcrun --show-sdk-platform-path)/Developer/Library/Frameworks"
DYLD_LIBRARY_PATH="$(xcrun --show-sdk-platform-path)/Developer/usr/lib"
```

With those set, the helper runs the bundle and writes the stream. No manifest is loaded.

## Decision

Per mutant, run `swiftpm-testing-helper` with the built bundle and the framework search
paths, writing the event stream to a named pipe.

The helper is located relative to the `swift` on the resolved toolchain rather than
hard-coded, and `doctor` reports whether it is there — a machine where it is missing
should be told so before a run starts, not after the first mutant fails to launch.

## Consequences

**The per-mutant cost is the test process and nothing else.** No package description, no
build plan, no dependency resolution. The Θ(N · package description) term disappears.

**The event stream really streams.** Pointed at a named pipe, swift-testing writes each
event as it happens. Measured: in a suite holding a four-second test, the first failure
arrived at 0.01s and the process group was killed while that test was still running. A
mutant costs "time until something notices", not "time for the whole suite".

**`isFailure` is the field that decides a kill.** A `withKnownIssue` block records an issue
with `severity: "error"` and `isFailure: false`. Keying on severity would report a mutant
as killed by a test documented as currently failing — a kill credited to a test that never
passed. Since Swift 6.3 an issue may also be a warning (ST-0013), and that is not a failure
either; both cases come out of the one field.

**Tests run in parallel by default and must not.** Every test in the fixture reported
`testStarted` within the same 0.01s. Which test killed a mutant is then a race, and
coverage attribution built on it would be a different answer each run. Mutants run in
parallel; the tests inside one mutant run in series.

**This is a private interface.** `swiftpm-testing-helper` lives in `libexec` and carries no
compatibility promise, exactly as `ocaml-mutants` treats compiler-libs. It is confined to
the SwiftPM adapter, the toolchain is pinned, and `doctor` fails loudly rather than a run
failing obscurely. The fallback when it is absent is `swift test`, which is slower by a term
that grows with the package but is a supported interface.

**Linux is not this.** There the test target links as an executable and can be run
directly. The adapter asks the platform rather than assuming either shape.
