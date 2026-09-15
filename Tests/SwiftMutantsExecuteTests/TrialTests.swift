// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsBuild
import SwiftMutantsRunner
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsExecute

/// One mutant, from starting the tests to knowing the answer.
///
/// Driven by a scripted stand-in for a test bundle rather than a real one: a shell script
/// that reads the arguments a real bundle is given, writes the events a real bundle writes,
/// and exits how a real bundle exits. That makes every case testable in milliseconds -
/// including the ones a real suite cannot be made to produce on demand, like a bundle that
/// dies halfway through or one that says nothing at all.
@Suite("Trials")
struct TrialTests {

    /// A scripted test bundle, and the way to take it away again.
    struct Fake {
        let plan: TestPlan
        let scratch: URL
        func cleanUp() { try? FileManager.default.removeItem(at: scratch) }
    }

    /// Writes a shell script that behaves like a built test bundle.
    ///
    /// `body` is shell, with `$STREAM` bound to whatever was passed for
    /// `--event-stream-output-path` and `$SWIFT_MUTANTS_ACTIVE` to the mutant, if any.
    static func fake(_ body: String) throws -> Fake {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-trial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let script = scratch.appending(path: "bundle.sh")
        try Data(
            """
            #!/bin/sh
            STREAM=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --event-stream-output-path) STREAM="$2"; shift 2 ;;
                *) ARGS="$ARGS $1"; shift ;;
              esac
            done
            echo "$ARGS" > '\(scratch.path)/argv.txt'
            env > '\(scratch.path)/env.txt'
            \(body)
            """.utf8
        ).write(to: script)
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

    /// The events a passing suite writes.
    static func passing(_ test: String = "P.S/f()") -> String {
        """
        printf '%s\\n' \\
          '{"kind":"event","payload":{"kind":"runStarted"}}' \\
          '{"kind":"event","payload":{"kind":"testStarted","testID":"\(test)"}}' \\
          '{"kind":"event","payload":{"kind":"testEnded","testID":"\(test)"}}' \\
          '{"kind":"event","payload":{"kind":"runEnded"}}' > "$STREAM"
        exit 0
        """
    }

    static func trial(_ fake: Fake, timeout: Duration = .seconds(30)) -> Trial {
        Trial(
            bundles: TestBundles(plans: [fake.plan]),
            runner: Runner(recorder: TraceRecorder()),
            scratch: fake.scratch,
            budget: .flat(timeout)
        )
    }

    @Test("calls a mutant nothing noticed survived")
    func survived() async throws {
        let fake = try Self.fake(Self.passing())
        defer { fake.cleanUp() }
        #expect(await Self.trial(fake).run(activating: 3).outcome == .survived)
    }

    @Test("calls a mutant a test failed on killed, and says which test")
    func killed() async throws {
        let fake = try Self.fake(
            """
            printf '%s\\n' \\
              '{"kind":"event","payload":{"kind":"runStarted"}}' \\
              '{"kind":"event","payload":{"kind":"testStarted","testID":"P.S/f()"}}' \\
              '{"kind":"event","payload":{"kind":"issueRecorded","testID":"P.S/f()",\
            "issue":{"isFailure":true,"isKnown":false},"messages":[{"text":"3 == 4"}]}}' > "$STREAM"
            sleep 30
            """
        )
        defer { fake.cleanUp() }

        let verdict = await Self.trial(fake).run(activating: 3)
        #expect(verdict.outcome == .killed)
        #expect(verdict.killedBy == ["P.S/f()"])
        #expect(verdict.firstFailure == "3 == 4")
        // Not `.exited`: the suite was still running and this tool ended it. Two mutants
        // that are both killed are not the same news, and this is the difference.
        #expect(verdict.termination == .stopped)
    }

    /// The whole economy of the thing: the script would sleep for thirty seconds after its
    /// failure, and the trial does not wait for it.
    @Test("does not wait for a suite whose answer is already known")
    func stopsEarly() async throws {
        let fake = try Self.fake(
            """
            printf '%s\\n' \\
              '{"kind":"event","payload":{"kind":"runStarted"}}' \\
              '{"kind":"event","payload":{"kind":"testStarted","testID":"P.S/f()"}}' \\
              '{"kind":"event","payload":{"kind":"issueRecorded","testID":"P.S/f()",\
            "issue":{"isFailure":true}}}' > "$STREAM"
            sleep 30
            touch '\(FileManager.default.temporaryDirectory.path)/swift-mutants-should-not-exist'
            """
        )
        defer { fake.cleanUp() }

        // A deadline shorter than the sleep, so a trial that waited would time out rather
        // than pass - the assertion is about the outcome, not about the clock.
        let verdict = await Self.trial(fake, timeout: .seconds(10)).run(activating: 3)
        #expect(verdict.outcome == .killed)
        #expect(verdict.termination == .stopped)
    }

    @Test("tells the tests which mutant is awake")
    func passesTheMutant() async throws {
        let fake = try Self.fake(Self.passing())
        defer { fake.cleanUp() }
        _ = await Self.trial(fake).run(activating: 41)

        let environment = try String(
            contentsOf: fake.scratch.appending(path: "env.txt"), encoding: .utf8)
        #expect(environment.contains("SWIFT_MUTANTS_ACTIVE=41"))
        #expect(environment.contains("SWIFT_MUTANTS=1"))
        #expect(environment.contains("SWIFT_MUTANTS_TEST_TOKEN=0"))
    }

    /// The instrumented baseline: the same tree and the same process, nothing awake. Its
    /// passing is what proves the guards preserved the program.
    @Test("wakes nothing for the baseline")
    func baselineWakesNothing() async throws {
        let fake = try Self.fake(Self.passing())
        defer { fake.cleanUp() }
        let verdict = await Self.trial(fake).run(activating: nil)
        #expect(verdict.termination == .exited(0))

        let environment = try String(
            contentsOf: fake.scratch.appending(path: "env.txt"), encoding: .utf8)
        #expect(!environment.contains("SWIFT_MUTANTS_ACTIVE"))
        #expect(verdict.outcome == .survived)
    }

    /// swift-testing runs tests concurrently by default, and "which test killed this
    /// mutant" is then a race. Measured on the pinned toolchain: four tests, three
    /// overlapping pairs by default and none with the flag.
    @Test("asks for the tests to run one at a time")
    func asksForSerialTests() async throws {
        let fake = try Self.fake(Self.passing())
        defer { fake.cleanUp() }
        _ = await Self.trial(fake).run(activating: 1)

        let argv = try String(contentsOf: fake.scratch.appending(path: "argv.txt"), encoding: .utf8)
        #expect(argv.contains("--no-parallel"))
        #expect(argv.contains("--event-stream-version 6.3"))
    }

    /// Arguments somebody gave for their own tests are passed through exactly as written
    /// and never interpreted: a tool that parsed them would be guessing at somebody's test
    /// runner, and guessing wrong is a mutant reported as surviving tests that never ran.
    @Test("hands the tests the arguments they were given, verbatim")
    func passesThroughTestArguments() async throws {
        let fake = try Self.fake(Self.passing())
        defer { fake.cleanUp() }
        let plan = TestPlan(
            executable: fake.plan.executable,
            arguments: fake.plan.arguments + ["--skip", "Slow", "--filter", "a b"],
            environment: fake.plan.environment,
            directory: fake.plan.directory
        )
        _ = await Trial(
            bundles: TestBundles(plans: [plan]),
            runner: Runner(recorder: TraceRecorder()),
            scratch: fake.scratch,
            budget: .flat(.seconds(30))
        ).run(activating: 1)

        let argv = try String(contentsOf: fake.scratch.appending(path: "argv.txt"), encoding: .utf8)
        #expect(argv.contains("--skip Slow"))
        #expect(argv.contains("--filter a b"))
        // Still followed by what this tool needs to watch the run.
        #expect(argv.contains("--no-parallel"))
    }

    /// A mutant that traps takes the process with it, and that is the mutant being caught.
    @Test("calls a bundle that died mid-suite killed")
    func crashed() async throws {
        let fake = try Self.fake(
            """
            printf '%s\\n' \\
              '{"kind":"event","payload":{"kind":"runStarted"}}' \\
              '{"kind":"event","payload":{"kind":"testStarted","testID":"P.S/f()"}}' > "$STREAM"
            exit 139
            """
        )
        defer { fake.cleanUp() }
        #expect(await Self.trial(fake).run(activating: 3).outcome == .killed)
    }

    /// A bundle that never ran a test proves nothing, whatever it exited with.
    @Test("calls a bundle that never started errored")
    func neverStarted() async throws {
        let fake = try Self.fake("exit 0")
        defer { fake.cleanUp() }
        #expect(await Self.trial(fake).run(activating: 3).outcome == .errored)
    }

    @Test("calls a bundle that ran out of time timed out")
    func timedOut() async throws {
        let fake = try Self.fake(
            """
            printf '%s\\n' \\
              '{"kind":"event","payload":{"kind":"runStarted"}}' \\
              '{"kind":"event","payload":{"kind":"testStarted","testID":"P.S/f()"}}' > "$STREAM"
            sleep 30
            """
        )
        defer { fake.cleanUp() }
        let verdict = await Self.trial(fake, timeout: .milliseconds(600)).run(activating: 3)
        #expect(verdict.outcome == .timedOut)
    }

    @Test("says a bundle that is not there could not run")
    func missingBundle() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-trial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let trial = Trial(
            bundles: TestBundles(plans: [
                TestPlan(
                    executable: "/no/such/bundle",
                    arguments: [],
                    environment: [:],
                    directory: scratch.path
                )
            ]),
            runner: Runner(recorder: TraceRecorder()),
            scratch: scratch
        )
        #expect(await trial.run(activating: 1).outcome == .errored)
    }

    /// A trial leaves nothing of its own behind: the pipe it made is removed whether the
    /// tests passed, failed, crashed or never started.
    @Test("takes its pipe away again")
    func cleansUpItsPipe() async throws {
        let fake = try Self.fake(Self.passing())
        defer { fake.cleanUp() }
        _ = await Self.trial(fake).run(activating: 5)

        let left = try FileManager.default.contentsOfDirectory(atPath: fake.scratch.path).sorted()
        #expect(left == ["argv.txt", "bundle.sh", "env.txt"])
    }
}
