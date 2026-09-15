// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import SwiftMutantsCore
public import SwiftMutantsExecute
import SwiftMutantsRunner

/// Runs a package's tests through Xcode, with chosen mutants awake.
///
/// The Xcode path's answer to ``Trial``, and it is not a variation on it. The SwiftPM path
/// launches the test bundle and watches an event stream, so it stops at the first failure
/// and a mutant costs the time until something notices. There is no event stream here -
/// measured, not assumed: an Xcode-built bundle launched the same way produces none - so
/// this runs a filtered suite to the end and reads the result bundle afterwards.
///
/// What comes back is the same ``Verdict`` either way, which is what lets one scheduler
/// drive both. The cost is different and is written down rather than hidden: no early stop,
/// so a mutant costs a whole filtered suite. Coverage narrowing still applies, which is the
/// saving that matters most.
public struct XcodeHost: MutantHost {

    private let driver: XcodeDriver
    private let document: Xctestrun
    private let destination: String
    private let scratch: URL
    private let worker: Int

    /// Prepares to run mutants through `driver`, waking them in copies of `document`.
    ///
    /// `worker` names this host's copies apart from every other worker's. Two workers
    /// writing one document would be two workers waking each other's mutants, which is a
    /// score about a program nobody ran.
    public init(
        driver: XcodeDriver,
        document: Xctestrun,
        destination: String,
        scratch: URL,
        worker: Int = 0
    ) {
        self.driver = driver
        self.document = document
        self.destination = destination
        self.scratch = scratch
        self.worker = worker
    }

    /// What this host calls the document it writes before every run.
    ///
    /// One per worker, and one *is* enough: a worker runs one thing at a time, and the
    /// document is written fresh each time from the one xcodebuild produced, so whatever it
    /// held before is gone. A second name for probing would be a distinction no test could
    /// justify.
    ///
    /// Per worker is the part that matters. Two workers writing one document would be two
    /// workers waking each other's mutants - and the run would still finish, with a score
    /// about a program nobody ran. A value rather than a literal inside the call, so that
    /// the claim is something a test can hold without starting Xcode twice.
    public var documentName: String { "swift-mutants-\(worker)" }

    /// Runs the tests with these mutants awake.
    ///
    /// `settling` is accepted and ignored. It says when an answer is known from a stream of
    /// events, and there is no stream: the answer is known when the process ends. Ignored
    /// rather than refused because the protocol is what lets one scheduler drive both paths,
    /// and a host that refused a parameter it cannot honour would make the caller ask which
    /// path it is talking to.
    public func run(
        waking indices: [UInt32],
        onlyTests: [String]?,
        settling: StreamWatcher.Settlement
    ) async -> Verdict {
        let name = indices.isEmpty ? "base" : indices.map(String.init).joined(separator: "-")
        let woken: URL
        do {
            woken = try Self.waking(indices, in: document, named: documentName)
        } catch {
            return Self.failed(
                "the .xctestrun could not be written, so nothing was run: \(error)")
        }
        let bundle = scratch.appending(path: "result-\(worker)-\(name).xcresult")
        do {
            let results = try await driver.test(
                xctestrun: woken,
                destination: destination,
                resultBundle: bundle,
                onlyTests: onlyTests
            )
            return Self.verdict(of: results)
        } catch {
            // Nothing was established about this mutant, which is not the same as nothing
            // having failed. Saying so keeps it out of both columns of the score.
            return Self.failed(error.description)
        }
    }

    /// Runs one test with nothing awake, telling the runtime where to write what it
    /// reached.
    ///
    /// The same document trick as waking a mutant, with a different variable in it: there
    /// is no way to hand `test-without-building` an environment except through the
    /// `.xctestrun`, and the runtime reads where to write from the environment.
    ///
    /// Whether the process got to the end of its job is read from the result bundle rather
    /// than from the exit status, for the reason everything here is: `xcodebuild` exits
    /// non-zero for a failing test and for a project that will not load, and only one of
    /// those means the probe established nothing.
    public func probe(_ test: String, writingTo log: URL) async -> Int? {
        let woken: URL
        do {
            woken =
                try document
                .waking(["SWIFT_MUTANTS": "1", Prober.probeVariable: log.path])
                .write(named: documentName)
        } catch {
            return nil
        }
        let bundle = scratch.appending(path: "probe-\(worker)-\(abs(test.hashValue)).xcresult")
        guard
            let results = try? await driver.test(
                xctestrun: woken,
                destination: destination,
                resultBundle: bundle,
                onlyTests: [test]
            )
        else {
            return nil
        }
        // A probe runs with nothing awake, so a test that failed is a suite that was
        // already failing - and what it reached is not something to build a run on.
        //
        // No duration: this path has no event stream and no supervised process of its own
        // to have measured one, so it reports that the probe finished and says nothing
        // about what it cost. A deadline derived from nothing is the floor, which is the
        // direction to be wrong in.
        guard !results.started.isEmpty, !results.anythingFailed else { return nil }
        return 0
    }

    /// A copy of the document with these mutants awake, written where Xcode will find it.
    private static func waking(
        _ indices: [UInt32], in document: Xctestrun, named name: String
    ) throws -> URL {
        let variables =
            indices.isEmpty
            ? ["SWIFT_MUTANTS": "1"]
            : [
                "SWIFT_MUTANTS": "1",
                "SWIFT_MUTANTS_ACTIVE": indices.map(String.init).joined(separator: ","),
            ]
        return try document.waking(variables).write(named: name)
    }

    /// What a result bundle amounts to.
    ///
    /// A mutant is killed when a test failed with it awake, and survived when the suite ran
    /// and none did. A run that started no tests at all established nothing: the filter
    /// matched nothing, the bundle was empty, the scheme built something else - and reading
    /// that as a survivor is how a mutant nothing ran against goes into a report as a gap
    /// somebody should write a test for.
    private static func verdict(of results: TestResults) -> Verdict {
        guard !results.started.isEmpty else {
            return Self.failed("this run started no tests, so nothing is known about it")
        }
        return Verdict(
            outcome: results.anythingFailed ? .killed : .survived,
            killedBy: results.failed,
            firstFailure: results.failed.first,
            startedTests: results.started,
            durationMilliseconds: 0,
            termination: .exited(results.anythingFailed ? 1 : 0)
        )
    }

    /// A mutant nothing was established about, with the reason in it.
    private static func failed(_ reason: String) -> Verdict {
        Verdict(
            outcome: .errored,
            killedBy: [],
            firstFailure: reason,
            startedTests: [],
            durationMilliseconds: 0,
            termination: .couldNotStart(reason)
        )
    }
}
