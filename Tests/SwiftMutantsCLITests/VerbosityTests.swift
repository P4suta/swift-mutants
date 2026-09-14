// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import SwiftMutantsConsole
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsTrace
import Synchronization
import Testing

@testable import SwiftMutantsCLI

/// How much a run says.
///
/// Three audiences with three different needs, and one flag each. Somebody running this in
/// a script wants the exit code and nothing else. Somebody watching it wants to know it has
/// not hung. Somebody working out why it did something wants the account of what it ran.
///
/// The levels are additive, which is the only arrangement a person can hold in their head:
/// each says everything the one below it does, and more. A level that swapped one kind of
/// line for another would make `-v` a different report rather than a longer one.
@Suite("How much a run says")
struct VerbosityTests {

    static func lines(_ verbosity: Verbosity, _ stage: RunStage) -> [String] {
        let said = Mutex<[String]>([])
        RunProgress(verbosity: verbosity) { line in said.withLock { $0.append(line) } }
            .report(stage)
        return said.withLock { $0 }
    }

    static let stage = RunStage.discovering

    @Test("says nothing about a phase when it was told to be quiet")
    func quietSaysNothing() {
        #expect(Self.lines(.quiet, Self.stage).isEmpty)
    }

    @Test("says what phase it has reached by default")
    func normalSaysPhases() {
        #expect(!Self.lines(.normal, Self.stage).isEmpty)
    }

    /// Additive: every level above normal still says what normal says.
    @Test("says everything the level below says", arguments: [Verbosity.verbose, .veryVerbose])
    func additive(_ verbosity: Verbosity) {
        #expect(Self.lines(verbosity, Self.stage) == Self.lines(.normal, Self.stage))
    }

    @Test("orders the levels by how much they say")
    func ordered() {
        #expect(Verbosity.quiet < .normal)
        #expect(Verbosity.normal < .verbose)
        #expect(Verbosity.verbose < .veryVerbose)
    }

    /// What `-vv` adds: the account of what the run actually started, as it happens.
    @Test("says nothing about what it ran below the level that asked")
    func traceNeedsTheLevel() {
        let renderer = ConsoleRenderer(verbosity: .verbose)
        #expect(renderer.trace(Self.event) == nil)
        #expect(ConsoleRenderer(verbosity: .veryVerbose).trace(Self.event) != nil)
    }

    /// Two streams share one output and are told apart by shape rather than by being
    /// interleaved carefully: `grep '^  '` is the account, `grep -v '^  '` is the run.
    @Test("indents the account so it can be grepped apart from the run")
    func traceIsIndented() throws {
        let line = try #require(ConsoleRenderer(verbosity: .veryVerbose).trace(Self.event))
        #expect(line.hasPrefix("  "))
        #expect(line.contains("phase-begin"))
    }

    static var event: TraceEvent {
        TraceEvent(sequence: 1, kind: .phaseBegan(phase: "snapshot"))
    }
}

/// The closing block is the same block however a run was watched.
///
/// A run on a terminal draws while it works and a run in a pipe does not, and the one thing
/// that must not differ is what is left in the scrollback: somebody reads a CI log and a
/// colleague reads their terminal, and the two have to be talking about the same thing.
/// Pinning it means there is exactly one function that formats a summary.
@Suite("One summary, however it was watched")
struct SummaryIdentityTests {

    @Test("says the same block whatever the verbosity")
    func sameBlock() {
        let outcome = NarrationFixture.outcome(results: [
            NarrationFixture.result(.survived, tests: []),
            NarrationFixture.result(.killed, tests: ["MathTests/testAdd"]),
        ])
        let plain = Narration.summary(of: outcome)
        for verbosity in Verbosity.allCases where verbosity > .quiet {
            #expect(Narration.summary(of: outcome, verbosity: verbosity) == plain)
        }
    }

    /// Except when nobody asked for it. Quiet means the exit code and the errors.
    @Test("says no block at all when it was told to be quiet")
    func quietSaysNoBlock() {
        let outcome = NarrationFixture.outcome(results: [])
        #expect(Narration.summary(of: outcome, verbosity: .quiet).isEmpty)
    }
}

/// `-vv`: the account of what a run started, printed as it happens.
///
/// The same events `--trace` writes to a file, sent through the console the run is already
/// using - so somebody watching a run that is about to go wrong sees what it ran without
/// having to have asked for a trace directory beforehand. Which is the case that matters:
/// nobody turns on tracing before the run that fails.
@Suite("The account, as it happens")
struct LiveTraceTests {

    static func said(_ verbosity: Verbosity, recording kinds: [TraceEvent.Kind]) -> [String] {
        let said = Mutex<[String]>([])
        let recorder = TraceRecorder(
            sinks: [LiveTrace(verbosity: verbosity) { line in said.withLock { $0.append(line) } }])
        for kind in kinds { recorder.record(kind) }
        return said.withLock { $0 }
    }

    static let kinds: [TraceEvent.Kind] = [
        .phaseBegan(phase: "snapshot"),
        .phaseEnded(phase: "snapshot", durationMilliseconds: 231),
    ]

    @Test("prints one line per event at the level that asked")
    func printsEachEvent() {
        #expect(Self.said(.veryVerbose, recording: Self.kinds).count == 2)
    }

    @Test("prints nothing below that level", arguments: [Verbosity.quiet, .normal, .verbose])
    func silentBelow(_ verbosity: Verbosity) {
        #expect(Self.said(verbosity, recording: Self.kinds).isEmpty)
    }

    /// Indented, so the account and the run can be told apart in one scrollback.
    @Test("indents every line it prints")
    func indented() {
        #expect(Self.said(.veryVerbose, recording: Self.kinds).allSatisfy { $0.hasPrefix("  ") })
    }

    /// The recording still happens either way. A run that only recorded when somebody had
    /// asked would have nothing to show for the run nobody asked about, which is every run
    /// that fails.
    @Test("does not stop the run being recorded")
    func recordingIsUnconditional() {
        let recorder = TraceRecorder(sinks: [LiveTrace(verbosity: .quiet) { _ in }])
        recorder.record(.phaseBegan(phase: "snapshot"))
        #expect(recorder.totalRecorded() == 1)
        #expect(recorder.retainedEvents().count == 1)
    }
}

/// What the flags on one invocation amount to.
///
/// Parsed rather than asserted about a variable, because the thing that can be wrong is the
/// spelling: `-vv` has to be two of the same flag rather than an option taking a value, and
/// a tool that took `-vv` as `-v v` would fail with a message about an unexpected argument.
@Suite("The flags that decide how much is said")
struct VerbosityFlagTests {

    static func verbosity(_ arguments: [String]) throws -> Verbosity {
        try RunCommand.parse(arguments).verbosity
    }

    @Test("says the ordinary amount when nobody asked")
    func defaultIsNormal() throws {
        #expect(try Self.verbosity([]) == .normal)
    }

    @Test("counts the flag rather than reading a value after it")
    func countsTheFlag() throws {
        #expect(try Self.verbosity(["-v"]) == .verbose)
        #expect(try Self.verbosity(["-vv"]) == .veryVerbose)
        #expect(try Self.verbosity(["-v", "-v"]) == .veryVerbose)
    }

    /// A third one is not a fourth level. Somebody reaching for `-vvv` gets the most this
    /// says rather than an error about a level that does not exist.
    @Test("stops at the most it has to say")
    func stopsAtTheTop() throws {
        #expect(try Self.verbosity(["-vvv"]) == .veryVerbose)
    }

    @Test("says nothing but errors when told to be quiet")
    func quiet() throws {
        #expect(try Self.verbosity(["--quiet"]) == .quiet)
    }

    /// Both is somebody's mistake, and the quiet one is the safer to honour: a script told
    /// too little still works, and a script told too much has its output parsed wrong.
    @Test("prefers quiet when told both")
    func quietWins() throws {
        #expect(try Self.verbosity(["--quiet", "-vv"]) == .quiet)
    }
}
