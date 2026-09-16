// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import SwiftMutantsConsole
import SwiftMutantsCore
import SwiftMutantsDiscover
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

/// Whether a run draws, and what it leaves behind when it does.
///
/// Drawing is for a person watching a terminal. A pipe gets lines, because a log full of
/// cursor movement is a log nobody can read and a CI page full of it is worse. That is a
/// property of where the output is going rather than a preference, so it is decided by
/// asking - with a flag for the case where somebody knows better than the answer.
@Suite("Whether a run draws")
struct DrawingTests {

    static func decision(_ arguments: [String], terminal: Bool) throws -> Bool {
        try RunCommand.parse(arguments).draws(onATerminal: terminal)
    }

    @Test("draws on a terminal")
    func drawsOnATerminal() throws {
        #expect(try Self.decision([], terminal: true))
    }

    /// A log full of cursor movement is a log nobody can read.
    @Test("prints lines into a pipe")
    func linesIntoAPipe() throws {
        #expect(try !Self.decision([], terminal: false))
    }

    @Test("prints lines when it was told not to draw")
    func honoursTheFlag() throws {
        #expect(try !Self.decision(["--no-tui"], terminal: true))
    }

    /// Nothing to draw. A run told to say nothing but errors should not paint a progress
    /// bar over the terminal it was told to keep quiet in.
    @Test("draws nothing when it was told to be quiet")
    func quietDrawsNothing() throws {
        #expect(try !Self.decision(["--quiet"], terminal: true))
    }

    /// The account and a redrawing screen cannot share one terminal: the account is a
    /// stream of lines and the screen moves the cursor over the last three, so one would
    /// scroll the other away. `-vv` is the one somebody asked for by name.
    @Test("prints lines when it was asked for the account")
    func accountBeatsDrawing() throws {
        #expect(try !Self.decision(["-vv"], terminal: true))
        // `-v` is not the account, so it still draws.
        #expect(try Self.decision(["-v"], terminal: true))
    }
}

/// What a drawing run actually puts on the screen.
///
/// The decision to draw is one thing and the drawing is another, and only the second one
/// can be wrong in a way somebody sees. A run that drew a frame per phase but never updated
/// the counts, or that printed its lines *and* drew, would look fine in every test about
/// the decision.
@Suite("What a drawing run draws")
struct DrawnFramesTests {

    static func watching(_ stages: [RunStage]) -> (frames: [String], lines: [String]) {
        let frames = Mutex<[String]>([])
        let lines = Mutex<[String]>([])
        let progress = RunProgress(
            drawing: true,
            say: { line in lines.withLock { $0.append(line) } },
            draw: { text in frames.withLock { $0.append(text) } }
        )
        for stage in stages { progress.report(stage) }
        progress.finish()
        return (frames.withLock { $0 }, lines.withLock { $0 })
    }

    static func drawn(_ stages: [RunStage]) -> [String] { Self.watching(stages).frames }

    /// Lines and frames would scroll each other away, so a phase goes in the frame and
    /// nowhere else.
    @Test("says nothing it could draw instead")
    func drawsRatherThanSays() {
        #expect(Self.watching([.discovering, .proving, .building]).lines.isEmpty)
    }

    /// Except what will not fit in one. A frame is one line of headline, replaced by the
    /// next phase a second later; a finding about the package is several lines the reader
    /// has to keep. Drawing it would both break the fixed height the redraw rests on and
    /// wipe it off the screen immediately.
    ///
    /// So the frame stays where it is, the news is said under it, and drawing starts again
    /// below - which is the same thing `finish` already does for the summary.
    @Test("leaves the frame where it is and says the news that will not fit in one")
    func saysNewsUnderTheFrame() {
        let watched = Self.watching([
            .building, .skipped(["P.NeedsRepository/alphabet()"]), .baseline,
        ])
        let said = watched.lines.joined(separator: "\n")
        #expect(said.contains("alphabet()"), "\(watched.lines)")
        #expect(said.lowercased().contains("copy"), "\(watched.lines)")
        // And the phase in the frames is never the news: a frame holds one line.
        #expect(!watched.frames.joined().contains("alphabet()"), "\(watched.frames)")
    }

    @Test("draws one frame per stage, and one more to move past the last")
    func oneFramePerStage() {
        #expect(Self.drawn([.discovering, .proving, .building]).count == 4)
    }

    @Test("says what it is doing in the frame")
    func drawsThePhase() {
        let drawn = Self.drawn([.discovering]).joined()
        #expect(drawn.contains("reading the sources"))
    }

    /// The counts have to move, which is the entire reason for drawing rather than printing.
    @Test("moves the counts as mutants finish")
    func countsMove() {
        let results = (0..<3).map { _ in NarrationFixture.result(.killed, tests: ["T/t"]) }
        let drawn = Self.drawn(
            [.running(total: 3, processes: 3)] + results.map { RunStage.finished($0) })
        #expect(drawn.last(where: { $0.contains("killed") })?.contains("3/3") == true)
        #expect(drawn.last(where: { $0.contains("killed") })?.contains("3 killed") == true)
    }

    /// The phase stays while the counts move. A frame built from one stage alone would
    /// blank the half of itself that stage did not mention.
    @Test("keeps the phase while the counts move")
    func phaseSurvivesCounts() {
        let drawn = Self.drawn([
            .running(total: 1, processes: 1),
            .finished(NarrationFixture.result(.killed, tests: ["T/t"])),
        ])
        // The very last write is `finish()` moving past the frame, so the frame is the one
        // before it.
        let final = drawn.dropLast().last ?? ""
        #expect(final.contains("running"))
        #expect(final.contains("1/1"))
    }

    /// Nothing at all when it was told to be quiet, screen or no screen.
    @Test("draws nothing when it was told to be quiet")
    func quietDrawsNothing() {
        let frames = Mutex<[String]>([])
        let progress = RunProgress(
            verbosity: .quiet,
            drawing: true,
            say: { _ in },
            draw: { text in frames.withLock { $0.append(text) } }
        )
        progress.report(.discovering)
        #expect(frames.withLock { $0 }.isEmpty)
    }
}

/// The summary says it too, not only a command somebody has to think to run.
///
/// A row that stopped applying fails the run, and a run that failed for a reason only
/// `why-skipped` could tell you is a run whose exit code is a mystery.
@Suite("A summary says what stopped applying")
struct SummaryUnanchoredTests {

    @Test("says which of a project's own mutants had nothing to anchor to")
    func saysThem() {
        let outcome = NarrationFixture.outcome(
            results: [],
            unanchored: [
                UnanchoredMutant(
                    row: CustomMutant(
                        find: "input.isReady",
                        replace: "true",
                        reason: "hold frames until the memory runs out"
                    ),
                    occurrences: 0
                )
            ]
        )
        let said = Narration.summary(of: outcome).joined(separator: "\n")
        #expect(said.contains("hold frames until the memory runs out"))
    }

    @Test("says nothing when every one anchored")
    func silentWhenFine() {
        let said = Narration.summary(of: NarrationFixture.outcome(results: []))
            .joined(separator: "\n")
        #expect(!said.contains("anchor"))
    }
}
