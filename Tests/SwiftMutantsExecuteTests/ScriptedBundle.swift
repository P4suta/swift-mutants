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
    static func fake(
        failingFor failing: Set<UInt32>,
        failingBaselineTests: [String] = [],
        slowUntilRetried: Set<UInt32> = [],
        alwaysSlow: Set<UInt32> = []
    ) throws -> Fake {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-sched-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let script = scratch.appending(path: "bundle.sh")
        try Data(
            Self.script(
                failingFor: failing,
                slowUntilRetried: slowUntilRetried,
                alwaysSlow: alwaysSlow,
                in: scratch
            ).utf8
        ).write(to: script)

        // The baseline's events, written out rather than escaped into the script: a shell
        // heredoc holding JSON inside Swift string interpolation is a thing nobody should
        // have to read twice.
        if !failingBaselineTests.isEmpty {
            let events =
                [
                    """
                    {"kind":"event","payload":{"kind":"runStarted"}}
                    """
                ]
                + failingBaselineTests.flatMap { test in
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
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: script.path)

        return Fake(
            plan: TestPlan(
                executable: "/bin/sh",
                arguments: [script.path],
                environment: [:],
                directory: scratch.path
            ),
            scratch: scratch
        )
    }

    static func script(
        failingFor failing: Set<UInt32>,
        slowUntilRetried: Set<UInt32> = [],
        alwaysSlow: Set<UInt32> = [],
        in scratch: URL
    ) -> String {
        let failures = failing.map(String.init).sorted().joined(separator: " ")
        let slowness = Self.slowness(
            once: slowUntilRetried, always: alwaysSlow, in: scratch)
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
            for bad in \(failures); do
              if [ "$MUTANT" = "$bad" ]; then
                printf '%s\\n' \\
                  '{"kind":"event","payload":{"kind":"issueRecorded","testID":"P.S/f()",\
            "issue":{"isFailure":true}}}' > "$STREAM"
                rm -f "$LIVE/$MUTANT"
                exit 1
              fi
            done
            sleep 0.2
            printf '%s\\n' \\
              '{"kind":"event","payload":{"kind":"testEnded","testID":"P.S/f()"}}' \\
              '{"kind":"event","payload":{"kind":"runEnded"}}' > "$STREAM"
            rm -f "$LIVE/$MUTANT"
            exit 0
            """
    }

    /// Shell that makes some mutants slow: once, or every time.
    ///
    /// Once is the shape a suite has when eight copies of it share a machine - the mark it
    /// leaves survives, so the retry runs at full speed.
    static func slowness(once: Set<UInt32>, always: Set<UInt32>, in scratch: URL) -> String {
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
            """
    }
}
