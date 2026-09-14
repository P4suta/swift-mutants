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

    /// Two streams share one output, so they are separated by shape rather than by
    /// interleaving: `grep '^  '` is the account, `grep -v '^  '` is the run.
    @Test("indents a recorded event by exactly two spaces, and a run line by none")
    func accountAndRunAreSeparableByIndentation() throws {
        let renderer = ConsoleRenderer(verbosity: .veryVerbose)
        let line = try #require(
            renderer.trace(
                TraceEvent(
                    sequence: 4,
                    kind: .phaseEnded(phase: "snapshot", durationMilliseconds: 231)
                )
            )
        )
        #expect(line.hasPrefix("  "))
        #expect(!line.hasPrefix("   "))
    }

    /// The recorded stream is what `--trace` writes, printed as it happens. Below the
    /// level that asked for it there is nothing to print.
    @Test("prints the account only at the level that asked for it")
    func traceNeedsVeryVerbose() {
        let event = TraceEvent(sequence: 1, kind: .phaseBegan(phase: "snapshot"))
        for verbosity in [Verbosity.quiet, .normal, .verbose] {
            #expect(ConsoleRenderer(verbosity: verbosity).trace(event) == nil)
        }
        #expect(ConsoleRenderer(verbosity: .veryVerbose).trace(event) != nil)
    }

    /// An argument vector is meant to be selected and pasted, so it is printed on one line
    /// however wide, and never wrapped.
    @Test("prints a recorded command as one pasteable line")
    func recordedCommandIsOneLine() throws {
        let renderer = ConsoleRenderer(verbosity: .veryVerbose)
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

}
