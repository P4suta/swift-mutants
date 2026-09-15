// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Something that can run a package's tests: with mutants awake, or one at a time to
/// see what it reaches.
///
/// The one thing scheduling needs from a build system, and deliberately the only thing.
/// Which mutants are worth running together, which tests to offer them, when a timeout is
/// evidence and when it is only a busy machine - all of that is the scheduler's, and none
/// of it changes because the tests are started by a different program.
///
/// Two conformances, and they are not variations on one shape. The SwiftPM path launches
/// the test bundle and watches an event stream, so it can stop at the first failure and a
/// mutant costs the time until something notices. The Xcode path has no event stream -
/// measured, not assumed - so it runs a filtered suite to the end and reads the result
/// bundle afterwards. The verdict comes back the same either way, which is what lets one
/// scheduler drive both.
public protocol MutantHost: Sendable {

    /// Runs the tests with these mutants awake, and says what happened.
    ///
    /// An empty set is the instrumented baseline: the same tree, the same process, nothing
    /// activated. It has to pass, and a run whose instrumented baseline fails is a run
    /// whose every later answer would be about a program the user did not write.
    ///
    /// `onlyTests` is a narrowing, never a requirement: `nil` means the whole suite, which
    /// is what a run without coverage has to do. `settling` says when the answer is known,
    /// and a host with nothing to watch may reach it only when the process ends.
    ///
    /// Never throws. A mutant that traps, hangs or is refused is an answer about the
    /// program, and a host that threw for those would make the ordinary case an error.
    func run(
        waking indices: [UInt32],
        onlyTests: [String]?,
        settling: StreamWatcher.Settlement
    ) async -> Verdict

    /// Runs one test with nothing awake, telling the runtime to write what it reached.
    ///
    /// The other half of what a build system has to do, and it belongs beside the first:
    /// both are "run this package's tests in a particular way", and a host that could do
    /// one of them would be a build system this tool can measure half of.
    ///
    /// - Parameters:
    ///   - test: the one test to run, and no other.
    ///   - log: where the runtime is told to write the guards it evaluated. The caller made
    ///     it empty first, so a file that exists and is empty means the test reached
    ///     nothing while a file that could not be read means the process did not finish.
    /// - Returns: whether the process got to the end of its job. `false` establishes
    ///   nothing about the test, which is not the same as the test reaching nothing - and
    ///   the difference is a mutant reported as unreachable that a test catches every day.
    func probe(_ test: String, writingTo log: URL) async -> Bool
}

extension MutantHost {

    /// Runs the tests with one mutant awake, or with none at all.
    public func run(
        activating index: UInt32?,
        onlyTests: [String]? = nil,
        settling: StreamWatcher.Settlement = .oneMutant
    ) async -> Verdict {
        await run(waking: index.map { [$0] } ?? [], onlyTests: onlyTests, settling: settling)
    }
}
