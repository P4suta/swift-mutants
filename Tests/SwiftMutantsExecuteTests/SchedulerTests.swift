// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsBuild
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import SwiftMutantsRunner
import SwiftMutantsTrace
import Synchronization
import Testing

@testable import SwiftMutantsExecute

/// Running every mutant, a few at a time, and coming back with an answer that does not
/// depend on which worker was quickest.
@Suite("Scheduler")
struct SchedulerTests {

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
                *) shift ;;
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
            ls "$LIVE" | wc -l >> '\(scratch.path)/inflight.txt'
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

    static func path() -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    /// Six mutants in one file, from the real instrumenter rather than made up.
    static func mutants() throws -> [InstrumentedMutant] {
        let source = """
            func f(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Bool {
                let one = a < b
                let two = c > d
                return one && two
            }
            """
        let discovery = Discover.candidates(in: source, at: Self.path())
        return try Instrument.file(source, discovery: discovery).mutants
            .sorted { $0.index < $1.index }
    }

    static func scheduler(
        _ fake: Fake, jobs: Int = 3, timeout: Duration = .seconds(30)
    ) -> Scheduler {
        Scheduler(
            plan: fake.plan,
            runner: Runner(recorder: TraceRecorder()),
            scratch: fake.scratch,
            timeout: timeout,
            jobs: jobs
        )
    }

    @Test("reports every mutant it was given")
    func reportsEveryMutant() async throws {
        let mutants = try Self.mutants()
        let fake = try Self.fake(failingFor: [])
        defer { fake.cleanUp() }

        let results = await Self.scheduler(fake).run(mutants, in: Self.path())
        #expect(results.count == mutants.count)
        #expect(results.allSatisfy { $0.verdict.outcome == .survived })
    }

    /// Which worker finishes first is a fact about the machine. A report that changed
    /// shape because a machine was busy could not be diffed against yesterday's.
    @Test("reports them in the order it was given, not the order they finished")
    func keepsTheOrder() async throws {
        let mutants = try Self.mutants()
        // The first fails immediately and the rest sleep, so completion order is certainly
        // not the order they were given in.
        let fake = try Self.fake(failingFor: [mutants[0].index])
        defer { fake.cleanUp() }

        let results = await Self.scheduler(fake).run(mutants, in: Self.path())
        #expect(results.map(\.identity) == mutants.map(\.identity))
    }

    @Test("says which mutants the tests caught")
    func saysWhatWasCaught() async throws {
        let mutants = try Self.mutants()
        let caught = Set([mutants[1].index, mutants[3].index])
        let fake = try Self.fake(failingFor: caught)
        defer { fake.cleanUp() }

        let results = await Self.scheduler(fake).run(mutants, in: Self.path())
        let killed = results.filter { $0.verdict.outcome == .killed }.map(\.identity)
        #expect(Set(killed) == Set([mutants[1].identity, mutants[3].identity]))
    }

    /// Asked of the processes themselves rather than of the scheduler, because a scheduler
    /// that miscounted its own workers would agree with itself.
    @Test("runs no more at once than it was allowed")
    func respectsTheLimit() async throws {
        let mutants = try Self.mutants()
        let fake = try Self.fake(failingFor: [])
        defer { fake.cleanUp() }

        _ = await Self.scheduler(fake, jobs: 2).run(mutants, in: Self.path())

        let counts = try String(
            contentsOf: fake.scratch.appending(path: "inflight.txt"), encoding: .utf8
        )
        .split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        #expect(!counts.isEmpty)
        #expect(counts.max() ?? 0 <= 2, "saw \(counts.max() ?? 0) processes at once")
    }

    @Test("runs one at a time when told to")
    func serial() async throws {
        let mutants = try Self.mutants()
        let fake = try Self.fake(failingFor: [])
        defer { fake.cleanUp() }

        _ = await Self.scheduler(fake, jobs: 1).run(mutants, in: Self.path())

        let counts = try String(
            contentsOf: fake.scratch.appending(path: "inflight.txt"), encoding: .utf8
        )
        .split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        #expect(counts.max() ?? 0 == 1)
    }

    /// Nothing to run is a valid answer and must not be a hang or a crash.
    @Test("holds a catalogue with nothing in it")
    func empty() async throws {
        let fake = try Self.fake(failingFor: [])
        defer { fake.cleanUp() }
        #expect(await Self.scheduler(fake).run([], in: Self.path()).isEmpty)
    }

    /// The instrumented baseline wakes nothing. Its passing is what says the guards left
    /// the program alone.
    @Test("runs a baseline with nothing awake")
    func baseline() async throws {
        // Scripted to fail for mutant zero, which is what a baseline that woke *something*
        // would have woken. Without that, a baseline that activated the first mutant would
        // pass for the same reason the real baseline does, and say nothing.
        let fake = try Self.fake(failingFor: [0])
        defer { fake.cleanUp() }
        #expect(await Self.scheduler(fake).baseline().outcome == .survived)
    }

    /// A baseline is a diagnosis rather than a verdict. Stopping at the first failure
    /// would name one test when the cause is usually a family of them - a lint gate, a
    /// golden file, a check on imports, all of which instrumentation upsets together.
    @Test("runs a failing baseline to the end and names every test that failed")
    func baselineNamesEverything() async throws {
        let fake = try Self.fake(failingFor: [], failingBaselineTests: ["P.S/a()", "P.S/b()"])
        defer { fake.cleanUp() }

        let baseline = await Self.scheduler(fake).baseline()
        #expect(baseline.outcome == .killed)
        #expect(baseline.killedBy == ["P.S/a()", "P.S/b()"])
    }

    @Test("tells somebody about each answer as it arrives")
    func reportsProgress() async throws {
        let mutants = try Self.mutants()
        let fake = try Self.fake(failingFor: [])
        defer { fake.cleanUp() }

        let seen = Mutex(0)
        _ = await Self.scheduler(fake).run(mutants, in: Self.path()) { _ in
            seen.withLock { $0 += 1 }
        }
        #expect(seen.withLock { $0 } == mutants.count)
    }

    /// A mutant the compiler refused never ran, so counting only what executed would drop
    /// it out of the report entirely.
    @Test("counts rejections it never ran")
    func countsRejections() async throws {
        let mutants = try Self.mutants()
        let fake = try Self.fake(failingFor: [mutants[0].index])
        defer { fake.cleanUp() }

        let results = await Self.scheduler(fake).run(mutants, in: Self.path())
        let summary = try #require(RunSummary.of(results, rejected: 2))
        #expect(summary.killed == 1)
        #expect(summary.survived == mutants.count - 1)
        #expect(summary.rejected == 2)
        #expect(summary.total == mutants.count + 2)
    }
}

/// Running a mutant again when the first answer was a deadline.
///
/// A killed mutant stops at the first test that notices it; a surviving mutant runs the
/// whole suite. So the mutants that meet a deadline are, overwhelmingly, the survivors -
/// and a deadline counts as a detection. Measured on this repository before any of this
/// existed: 592 mutants, 82 deadlines, 0 survivors reported, and a score of 100% that was
/// not true of anything.
@Suite("Retrying deadlines")
struct RetryTests {

    typealias Fake = SchedulerTests.Fake

    static func mutants() throws -> [InstrumentedMutant] { try SchedulerTests.mutants() }

    /// The reason retries exist, and it is not hypothetical.
    ///
    /// A killed mutant stops at the first test that notices it; a surviving mutant runs
    /// the whole suite. So the mutants that meet a deadline are, overwhelmingly, the
    /// survivors - and counting a deadline as a detection turns every one of them into a
    /// kill. Measured on this repository: 592 mutants, 82 deadlines, 0 survivors reported,
    /// and a score of 100%, which was not true of anything.
    @Test("runs a mutant that ran out of time again, and takes the second answer")
    func retriesTimeouts() async throws {
        let mutants = try Self.mutants()
        let fake = try SchedulerTests.fake(failingFor: [], slowUntilRetried: [mutants[2].index])
        defer { fake.cleanUp() }

        // A deadline the slow pass certainly misses and the quick one certainly meets.
        let results = await SchedulerTests.scheduler(fake, timeout: .milliseconds(700))
            .run(mutants, in: SchedulerTests.path())
        let retried = try #require(results.first { $0.identity == mutants[2].identity })
        #expect(retried.verdict.outcome == .survived)
        #expect(retried.attempts == 2)

        // Everything else was answered the first time.
        #expect(results.filter { $0.attempts > 1 }.count == 1)
    }

    /// A mutant that runs out of time twice, the second time alone, has earned it.
    @Test("keeps the verdict when a mutant runs out of time twice")
    func confirmedTimeout() async throws {
        let mutants = try Self.mutants()
        let fake = try SchedulerTests.fake(failingFor: [], alwaysSlow: [mutants[1].index])
        defer { fake.cleanUp() }

        let results = await SchedulerTests.scheduler(fake, timeout: .milliseconds(700))
            .run(mutants, in: SchedulerTests.path())
        let stuck = try #require(results.first { $0.identity == mutants[1].identity })
        #expect(stuck.verdict.outcome == .timedOut)
        #expect(stuck.attempts == 2)
    }
}
