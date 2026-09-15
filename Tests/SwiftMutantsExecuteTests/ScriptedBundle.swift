// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsBuild
import Testing

/// A stand-in for a built test bundle, written as shell.
///
/// It reads the arguments a real bundle is given, writes the events a real bundle writes,
/// and exits how a real bundle exits - so every case is testable in milliseconds, including
/// the ones a real suite cannot be made to produce on demand: a bundle that dies halfway
/// through, one that is slow only the first time, one that never starts a test.
enum ScriptedBundle {

    struct Fake {
        let plan: TestPlan
        let scratch: URL
        func cleanUp() { try? FileManager.default.removeItem(at: scratch) }
    }

    /// A scripted test bundle that fails for some mutants and passes for the rest.
    ///
    /// It also records that it ran, so a test can ask how many were in flight at once
    /// rather than trusting the scheduler's own account of itself.
    /// What a scripted bundle should do.
    ///
    /// Gathered into one value rather than eight parameters, because a fixture builder
    /// with eight of them is a thing nobody can read at a call site.
    struct Script {
        var failing: Set<UInt32> = []

        /// Mutants that take the process down with them, the way a trap does.
        ///
        /// A test bundle that traps dies on a signal *without writing a failure event*:
        /// there is no assertion, there is no `issueRecorded`, the stream simply stops.
        /// That is the strongest kill there is - the mutant did not change an answer, it
        /// destroyed the program - and it is the one shape a fixture built out of failure
        /// events cannot produce by scripting a failure.
        var trapping: Set<UInt32> = []

        /// The same script, with these mutants taking the process down.
        func trapping(_ mutants: Set<UInt32>) -> Self {
            var copy = self
            copy.trapping = mutants
            return copy
        }
        var failingBaselineTests: [String] = []
        var slowUntilRetried: Set<UInt32> = []
        var alwaysSlow: Set<UInt32> = []
        var slowBaseline = false
        var failingTests: [String: String] = [:]
        var failingWhatever: String?
        var neverStarting = false
    }

    static func fake(
        failingFor failing: Set<UInt32>,
        failingBaselineTests: [String] = [],
        slowUntilRetried: Set<UInt32> = [],
        alwaysSlow: Set<UInt32> = [],
        slowBaseline: Bool = false,
        failingTests: [String: String] = [:],
        failingWhatever: String? = nil,
        neverStarting: Bool = false,
        trapping: Set<UInt32> = []
    ) throws -> Fake {
        try Self.fake(
            Script(
                failing: failing,
                failingBaselineTests: failingBaselineTests,
                slowUntilRetried: slowUntilRetried,
                alwaysSlow: alwaysSlow,
                slowBaseline: slowBaseline,
                failingTests: failingTests,
                failingWhatever: failingWhatever,
                neverStarting: neverStarting
            ).trapping(trapping))
    }

    static func fake(_ script: Script) throws -> Fake {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-sched-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appending(path: "bundle.sh")
        try Data(Self.body(of: script, in: scratch).utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: file.path)

        // Made empty before anything runs, so that "nothing ran" is an empty file rather
        // than a missing one. The two are the same absence otherwise, and a test that
        // reads one of these would throw a file error on a machine where a process failed
        // to start - reporting a missing file instead of the count it was asserting.
        // Exactly the distinction the probe log is built around, and a flake found here.
        for written in ["argv.txt", "inflight.txt", "tokens.txt"] {
            FileManager.default.createFile(
                atPath: scratch.appending(path: written).path, contents: Data())
        }

        if !script.failingBaselineTests.isEmpty {
            try Self.baselineEvents(script.failingBaselineTests, in: scratch)
        }
        return Fake(
            plan: TestPlan(
                executable: "/bin/sh",
                arguments: [file.path],
                environment: [:],
                directory: scratch.path
            ),
            scratch: scratch
        )
    }

    /// The shell a scripted bundle runs.
    static func body(of script: Script, in scratch: URL) -> String {
        script.neverStarting
            ? Self.silent
            : Self.script(
                failingFor: script.failing,
                trapping: script.trapping,
                slowUntilRetried: script.slowUntilRetried,
                alwaysSlow: script.alwaysSlow,
                slowBaseline: script.slowBaseline,
                failingTests: script.failingTests,
                failingWhatever: script.failingWhatever,
                in: scratch
            )
    }

    /// The baseline's events, written out rather than escaped into the script: a shell
    /// heredoc holding JSON inside Swift string interpolation is a thing nobody should
    /// have to read twice.
    static func baselineEvents(_ tests: [String], in scratch: URL) throws {
        let events =
            [
                """
                {"kind":"event","payload":{"kind":"runStarted"}}
                """
            ]
            + tests.flatMap { test in
                [
                    """
                    {"kind":"event","payload":{"kind":"testStarted","testID":"\(test)"}}
                    """,
                    """
                    {"kind":"event","payload":{"kind":"issueRecorded","testID":"\(test)",\
                    "issue":{"isFailure":true}}}
                    """,
                ]
            }
            + [
                """
                {"kind":"event","payload":{"kind":"runEnded"}}
                """
            ]
        try Data((events.joined(separator: "\n") + "\n").utf8)
            .write(to: scratch.appending(path: "baseline-events.jsonl"))
    }

    /// A bundle that starts nothing, the way a broken harness does.
    static let silent = "#!/bin/sh\nexit 97\n"

    static func script(
        failingFor failing: Set<UInt32>,
        trapping: Set<UInt32> = [],
        slowUntilRetried: Set<UInt32> = [],
        alwaysSlow: Set<UInt32> = [],
        slowBaseline: Bool = false,
        failingTests: [String: String] = [:],
        failingWhatever: String? = nil,
        in scratch: URL
    ) -> String {
        let named = Self.namedTests(failingTests) + Self.stranger(failingWhatever)
        let failures = failing.map(String.init).sorted().joined(separator: " ")
        let traps = trapping.map(String.init).sorted().joined(separator: " ")
        let slowness = Self.slowness(
            once: slowUntilRetried, always: alwaysSlow, baseline: slowBaseline, in: scratch)
        return """
            #!/bin/sh
            STREAM=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --event-stream-output-path) STREAM="$2"; shift 2 ;;
                *) ARGS="$ARGS $1"; shift ;;
              esac
            done
            MUTANT="${SWIFT_MUTANTS_ACTIVE:-base}"
            SCRIPTED='\(scratch.path)/baseline-events.jsonl'
            if [ "$MUTANT" = "base" ] && [ -f "$SCRIPTED" ]; then
              cat "$SCRIPTED" > "$STREAM"
              exit 1
            fi
            LIVE='\(scratch.path)/live'
            mkdir -p "$LIVE"
            touch "$LIVE/$MUTANT"
            echo "$ARGS" >> '\(scratch.path)/argv.txt'
            ls "$LIVE" | wc -l >> '\(scratch.path)/inflight.txt'
            if [ "$MUTANT" = "base" ]; then
              echo "$SWIFT_MUTANTS_TEST_TOKEN" >> '\(scratch.path)/tokens.txt'
            fi
            printf '%s\\n' \\
              '{"kind":"event","payload":{"kind":"runStarted"}}' \\
              '{"kind":"event","payload":{"kind":"testStarted","testID":"P.S/f()"}}' > "$STREAM"
            \(slowness)
            \(Self.trapping(traps))
            for bad in \(failures); do
              if [ "$MUTANT" = "$bad" ]; then
                printf '%s\\n' \\
                  '{"kind":"event","payload":{"kind":"issueRecorded","testID":"P.S/f()",\
            "issue":{"isFailure":true}}}' > "$STREAM"
                rm -f "$LIVE/$MUTANT"
                exit 1
              fi
            done
            \(named)
            sleep 0.2
            printf '%s\\n' \\
              '{"kind":"event","payload":{"kind":"testEnded","testID":"P.S/f()"}}' \\
              '{"kind":"event","payload":{"kind":"runEnded"}}' > "$STREAM"
            rm -f "$LIVE/$MUTANT"
            exit 0
            """
    }

    /// Shell that takes the process down, the way a trapping mutant does.
    ///
    /// A test bundle that traps dies on a signal *without writing a failure event*: there
    /// is no assertion, so there is no `issueRecorded`; the stream simply stops. That is
    /// the strongest kill there is - the mutant did not change an answer, it destroyed the
    /// program - and it is the one shape a fixture built out of failure events cannot
    /// produce by scripting a failure.
    ///
    /// Matched inside the list, because a batch wakes several at once and spells them
    /// `0,1,2`. A fixture that compared the whole variable against one index could never
    /// trap inside a batch, which is the case worth testing: alone, a trapping mutant was
    /// always answered correctly.
    static func trapping(_ indices: String) -> String {
        guard !indices.isEmpty else { return "" }
        return """
            for boom in \(indices); do
              case ",$MUTANT," in
                *",$boom,"*)
                  rm -f "$LIVE/$MUTANT"
                  kill -TRAP $$
                  sleep 5
                  ;;
              esac
            done
            """
    }

    /// Shell that fails a test nobody asked for, whatever the filters said.
    ///
    /// A bundle really can report a test the caller did not select - a suite-level failure,
    /// a setup that blew up, a filter that matched more than it meant. A batch handed one
    /// of those must not share it out.
    static func stranger(_ test: String?) -> String {
        guard let test else { return "" }
        return """

            printf '%s\\n' \\
              '{"kind":"event","payload":{"kind":"testStarted","testID":"\(test)"}}' \\
              '{"kind":"event","payload":{"kind":"issueRecorded","testID":"\(test)",\
            "issue":{"isFailure":true},"messages":[{"text":"a stranger"}]}}' >> "$STREAM"
            """
    }

    /// Shell that fails a named test whenever the filters ask for it.
    ///
    /// A batch is several mutants in one process, so a fixture has to be able to fail one
    /// test and not another - which is how a batched run is told apart from a lucky one.
    static func namedTests(_ failing: [String: String]) -> String {
        failing.sorted { $0.key < $1.key }.map { test, _ in
            """
            case "$ARGS" in
              *"\(test)"*)
                printf '%s\\n' \\
                  '{"kind":"event","payload":{"kind":"testStarted","testID":"\(test)"}}' \\
                  '{"kind":"event","payload":{"kind":"issueRecorded","testID":"\(test)",\
            "issue":{"isFailure":true},"messages":[{"text":"named failure"}]}}' >> "$STREAM"
                ;;
            esac
            """
        }.joined(separator: "\n            ")
    }

    /// Shell that makes some mutants slow: once, or every time.
    ///
    /// Once is the shape a suite has when eight copies of it share a machine - the mark it
    /// leaves survives, so the retry runs at full speed.
    /// How the bundle hangs, for a test about what happens when it does.
    ///
    /// `baseline` is the one a probe needs: a probe run has no mutant awake, so a set of
    /// mutant indices never matches it however it is spelled. Without this the script falls
    /// through to its ordinary body and exits cleanly, and a test about a run that had to
    /// be stopped is really a race between that body and the deadline - which is how one of
    /// these passed a thousand times and failed on a loaded machine.
    static func slowness(
        once: Set<UInt32>, always: Set<UInt32>, baseline: Bool = false, in scratch: URL
    ) -> String {
        let first = once.map(String.init).sorted().joined(separator: " ")
        let every = always.map(String.init).sorted().joined(separator: " ")
        return """
            for slow in \(first); do
              if [ "$MUTANT" = "$slow" ] && [ ! -f '\(scratch.path)/seen-'"$slow" ]; then
                touch '\(scratch.path)/seen-'"$slow"
                sleep 30
              fi
            done
            for slow in \(every); do
              if [ "$MUTANT" = "$slow" ]; then sleep 30; fi
            done
            \(baseline ? #"if [ "$MUTANT" = "base" ]; then sleep 30; fi"# : "")
            """
    }
}
