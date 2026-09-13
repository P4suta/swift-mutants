// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsConsole

/// How a run reads.
///
/// The renderer is a pure function from values to lines. That is what lets the dashboard
/// and the plain output agree: a run on a terminal draws, and then replays its summary
/// through this same renderer rather than formatting its own, so the block in the
/// scrollback is byte-identical to the one a pipe would have received.
@Suite("Console renderer")
struct ConsoleRendererTests {

    static func summary(
        killed: Int = 10,
        survived: Int = 3,
        uncovered: Int = 0,
        cached: Int = 0
    ) -> RunSummary {
        guard
            let summary = RunSummary(
                killed: killed,
                survived: survived,
                timedOut: 0,
                inconclusive: 0,
                errored: 0,
                notRun: 0,
                rejected: 0,
                equivalent: 0,
                uncovered: uncovered,
                cached: cached,
                expectedSurvivors: 0
            )
        else {
            fatalError("malformed summary fixture")
        }
        return summary
    }

    @Test("writes the closing block in the documented shape")
    func summaryBlock() {
        let renderer = ConsoleRenderer(verbosity: .normal, color: false)
        let lines = renderer.summary(
            Self.summary(),
            runIdentifier: "20260914T011213Z-67af",
            exitCode: 0,
            coverageGuided: false,
            cacheConsulted: false
        )
        #expect(
            lines == [
                "mutants 13  killed 10  survived 3  timeout 0  inconclusive 0  errored 0"
                    + "  not-run 0  rejected 0  equivalent 0",
                "score 76.92%  covered 76.92%",
                "run 20260914T011213Z-67af  exit 0",
            ]
        )
    }

    /// The column appears only where it means something. In a run without coverage there
    /// is no such thing as an uncovered mutant, and a zero would read as a finding.
    @Test("shows the uncovered column only in a coverage-guided run")
    func uncoveredColumnIsConditional() {
        let renderer = ConsoleRenderer(verbosity: .normal, color: false)
        let without = renderer.summary(
            Self.summary(uncovered: 0),
            runIdentifier: "r",
            exitCode: 0,
            coverageGuided: false,
            cacheConsulted: false
        )
        let with = renderer.summary(
            Self.summary(uncovered: 3),
            runIdentifier: "r",
            exitCode: 0,
            coverageGuided: true,
            cacheConsulted: false
        )
        #expect(!(without.first ?? "").contains("uncovered"))
        #expect((with.first ?? "").contains("uncovered 3"))
    }

    @Test("shows the cached column only when the cache was consulted")
    func cachedColumnIsConditional() {
        let renderer = ConsoleRenderer(verbosity: .normal, color: false)
        let with = renderer.summary(
            Self.summary(cached: 4),
            runIdentifier: "r",
            exitCode: 0,
            coverageGuided: false,
            cacheConsulted: true
        )
        #expect((with.first ?? "").contains("cached 4"))
    }

    /// There is no sentinel number for "nothing was measured", so the line says so.
    @Test("says N/A rather than inventing a percentage")
    func noScoreWithoutMeasurement() {
        let renderer = ConsoleRenderer(verbosity: .normal, color: false)
        let lines = renderer.summary(
            Self.summary(killed: 0, survived: 0),
            runIdentifier: "r",
            exitCode: 0,
            coverageGuided: false,
            cacheConsulted: false
        )
        #expect(lines.contains("score N/A  covered N/A"))
    }

    /// Two streams share one output, so they are separated by shape rather than by
    /// interleaving: `grep '^  '` is the account, `grep -v '^  '` is the run.
    @Test("indents a recorded event by exactly two spaces, and a run line by none")
    func accountAndRunAreSeparableByIndentation() {
        let renderer = ConsoleRenderer(verbosity: .veryVerbose, color: false)
        let recorded = renderer.trace(
            TraceEvent(sequence: 4, kind: .phaseEnded(phase: "snapshot", durationMilliseconds: 231))
        )
        let line = try? #require(recorded)
        #expect(line?.hasPrefix("  ") == true)
        #expect(line?.hasPrefix("   ") == false)

        let runLines = renderer.summary(
            Self.summary(),
            runIdentifier: "r",
            exitCode: 0,
            coverageGuided: false,
            cacheConsulted: false
        )
        #expect(runLines.allSatisfy { !$0.hasPrefix(" ") })
    }

    /// The recorded stream is what `--trace` writes, printed as it happens. Below the
    /// level that asked for it there is nothing to print.
    @Test("prints the account only at the level that asked for it")
    func traceNeedsVeryVerbose() {
        let event = TraceEvent(sequence: 1, kind: .phaseBegan(phase: "snapshot"))
        for verbosity in [ConsoleRenderer.Verbosity.quiet, .normal, .verbose] {
            #expect(ConsoleRenderer(verbosity: verbosity, color: false).trace(event) == nil)
        }
        #expect(ConsoleRenderer(verbosity: .veryVerbose, color: false).trace(event) != nil)
    }

    /// An argument vector is meant to be selected and pasted, so it is printed on one line
    /// however wide, and never wrapped.
    @Test("prints a recorded command as one pasteable line")
    func recordedCommandIsOneLine() throws {
        let renderer = ConsoleRenderer(verbosity: .veryVerbose, color: false)
        let execution = TraceEvent.Execution(
            label: "swift-build",
            arguments: ["swift", "build", "--build-tests", "--scratch-path", "/tmp/w0"],
            directory: "/tmp/snap/tree",
            environmentNames: ["PATH"],
            timeoutMilliseconds: 60000,
            exitCode: 0,
            durationMilliseconds: 231,
            standardOutputDigest: nil,
            standardOutputBytes: 0,
            failure: nil
        )
        let line = try #require(renderer.trace(TraceEvent(sequence: 7, kind: .exec(execution))))
        #expect(
            line
                == "  exec swift-build exit 0 231ms swift build --build-tests --scratch-path /tmp/w0"
        )
        #expect(!line.dropFirst(2).contains("\n"))
    }

    /// Colour is a property of where the output is going, never of what it says, so the
    /// same call with colour off produces bytes a golden file can hold.
    @Test("emits no escape sequences when colour is off")
    func noColourMeansNoEscapes() {
        let renderer = ConsoleRenderer(verbosity: .veryVerbose, color: false)
        let lines = renderer.summary(
            Self.summary(),
            runIdentifier: "r",
            exitCode: 2,
            coverageGuided: true,
            cacheConsulted: true
        )
        #expect(lines.allSatisfy { !$0.contains("\u{1b}") })
    }

    @Test("says nothing at all when asked to be quiet")
    func quietSaysNothing() {
        let renderer = ConsoleRenderer(verbosity: .quiet, color: false)
        #expect(
            renderer.summary(
                Self.summary(),
                runIdentifier: "r",
                exitCode: 0,
                coverageGuided: false,
                cacheConsulted: false
            ).isEmpty
        )
    }
}
