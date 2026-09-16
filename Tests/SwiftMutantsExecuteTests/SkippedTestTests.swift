// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsExecute

/// A test that does not run inside the copy.
///
/// Every run happens in a disposable copy of the package, which is what makes the
/// workspace read-only and what makes one build serve every mutant. A test whose fixtures
/// live *outside* the package - a document in the repository above it, a vector file, a
/// seed corpus - cannot run there, and a suite written to notice that declares itself
/// disabled rather than failing.
///
/// swift-testing says so: it emits `testSkipped` with the identifier. This tool read that
/// event as `other` and dropped it, so a skipped test was indistinguishable from a test
/// that ran and passed - and the mutants only that test covers come back as survivors
/// nobody can write a test for, for ever, because the test already exists and cannot run
/// here.
///
/// Reported from a package with five such suites, pinning a Base32 alphabet, two key
/// derivation strings and a salt order against the documents that specify them. Their
/// answer was to pin those constants a second time inside the package, which is right and
/// which nobody can arrive at while the tool is silent.
///
/// It is the prober's own warning arriving through a door nobody had checked: an empty
/// answer reads exactly like "this test reaches nothing", and that is how a mutant a test
/// catches every day comes back unmeasured.
@Suite("A test that does not run in the copy")
struct SkippedTestTests {

    static func watching(_ events: [(TestEvent.Kind, String)]) -> StreamWatcher {
        var watcher = StreamWatcher(settling: .wholeSuite)
        for (kind, test) in events {
            _ = watcher.observe(
                TestEvent(
                    kind: kind, testID: test, isFailure: false, isKnown: false, message: nil))
        }
        return watcher
    }

    static let baseline: [(TestEvent.Kind, String)] = [
        (.testStarted, "P.Ordinary/compares()"),
        (.testEnded, "P.Ordinary/compares()"),
        (.testSkipped, "P.NeedsRepository"),
        (.testSkipped, "P.NeedsRepository/alphabet()"),
        (.runEnded, ""),
    ]

    /// One, not two. A suite that steps aside emits `testSkipped` for itself *and* for
    /// each of its tests - measured directly against this toolchain, where one disabled
    /// suite holding one test produced two events. Counting both would report every
    /// skipped suite twice, and a person reading "ten tests skipped" about five would
    /// stop trusting the number.
    @Test("is counted once, rather than dropped or counted twice")
    func counted() {
        let verdict = Self.watching(Self.baseline).verdict(after: .exited(0))
        #expect(verdict.skippedTests == ["P.NeedsRepository/alphabet()"], "\(verdict.skippedTests)")
    }

    /// By name, because the answer is about a particular suite and "two tests were skipped"
    /// sends nobody anywhere.
    @Test("says which ones")
    func named() {
        let verdict = Self.watching(Self.baseline).verdict(after: .exited(0))
        #expect(verdict.skippedTests.contains("P.NeedsRepository/alphabet()"))
    }

    /// A test that was skipped did not pass. The baseline still passes - a skip is not a
    /// failure, and refusing to measure a package because one suite steps aside would be
    /// worse than saying so.
    @Test("does not make the baseline fail")
    func stillSurvives() {
        #expect(Self.watching(Self.baseline).verdict(after: .exited(0)).outcome == .survived)
    }

    /// And it is not counted among the tests that ran, which is the number a deadline and a
    /// per-test cost are derived from. Counting a test that did nothing would make every
    /// test look cheaper than it is.
    @Test("is not counted among the tests that ran")
    func notStarted() {
        let verdict = Self.watching(Self.baseline).verdict(after: .exited(0))
        #expect(verdict.startedTests == ["P.Ordinary/compares()"])
    }

    /// A package builds one test bundle per test target, and a mutant several could catch
    /// is several processes whose answers are read as one. A skip in a bundle other than
    /// the first would otherwise disappear at exactly that join - the same silence, one
    /// layer up from where it was fixed.
    @Test("survives being read across several bundles")
    func acrossBundles() {
        let plain = Self.watching([
            (.testStarted, "A.Ordinary/compares()"),
            (.testEnded, "A.Ordinary/compares()"),
            (.runEnded, ""),
        ]).verdict(after: .exited(0))
        let stepping = Self.watching(Self.baseline).verdict(after: .exited(0))
        let both = Verdict.across([plain, stepping])
        #expect(both.skippedTests == ["P.NeedsRepository/alphabet()"], "\(both.skippedTests)")
    }

    /// A run where nothing was skipped says nothing about skips.
    @Test("says nothing when everything ran")
    func nothingSkipped() {
        let verdict = Self.watching([
            (.testStarted, "P.Ordinary/compares()"),
            (.testEnded, "P.Ordinary/compares()"),
            (.runEnded, ""),
        ]).verdict(after: .exited(0))
        #expect(verdict.skippedTests.isEmpty)
    }
}
