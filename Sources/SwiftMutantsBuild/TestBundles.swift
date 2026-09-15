// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Every test bundle a package builds, and which of them a mutant has to face.
///
/// There used to be one. A SwiftPM package produced a single `<Package>PackageTests.xctest`
/// however many test targets it declared, and the whole of the scheduling rested on it:
/// one process per mutant, coverage narrowed test by test because there was nothing coarser
/// to narrow by.
///
/// SwiftPM's build system builds one bundle per test target instead - thirty of them for
/// this package. The tool refused to run rather than pick between them, which was the right
/// refusal and not a workable answer.
///
/// A test names its own bundle, which is what makes the narrowing survive. swift-testing
/// identifies a test as `Module.Suite/name()`, and a test target's module is the bundle it
/// is built into - so the tests a probe says reach a mutant also say which bundles that
/// mutant has to be offered to. Usually one, and never all of them once coverage is known.
public struct TestBundles: Sendable, Hashable {

    /// One plan per bundle, in a stable order.
    ///
    /// Sorted by module, so two runs of the same package start them in the same order and
    /// two reports of it can be diffed. Which bundle catches a mutant first is otherwise a
    /// fact about the filesystem.
    public let plans: [TestPlan]

    /// Records the bundles a build produced.
    public init(plans: [TestPlan]) {
        self.plans = plans.sorted { $0.module < $1.module }
    }

    /// The bundles that could run these tests, or all of them when that is not known.
    ///
    /// `nil` means nothing is known about which tests matter - a run without coverage -
    /// and then any test might be the one that notices. An empty array means the same
    /// here: "these tests, and there are none of them" describes a mutant nothing reaches,
    /// which the caller answers without starting a process at all, so arriving with one is
    /// a bug and running everything is the safe reading of it.
    ///
    /// A test naming a bundle this does not have widens rather than narrows, for the same
    /// reason: dropping it would answer the mutant with a suite that never contained its
    /// killer, and report a survivor that is not one.
    public func covering(_ tests: [String]?) -> [TestPlan] {
        guard let tests, !tests.isEmpty else { return plans }
        var wanted: Set<String> = []
        for test in tests {
            guard let module = Self.module(of: test) else { return plans }
            guard plans.contains(where: { $0.module == module }) else { return plans }
            wanted.insert(module)
        }
        return plans.filter { wanted.contains($0.module) }
    }

    /// The bundle a test lives in, read off the front of its name.
    ///
    /// `Module.Suite/name()`, and everything before the first `.` is the module. Nothing
    /// before the first `.`, or no `.` before the `/`, is a name this cannot place - and a
    /// name it cannot place widens the search rather than narrowing it.
    public static func module(of test: String) -> String? {
        guard let dot = test.firstIndex(of: ".") else { return nil }
        let module = test[test.startIndex..<dot]
        guard !module.isEmpty, !module.contains("/") else { return nil }
        return String(module)
    }

    /// The one bundle a test lives in, when this has it.
    public func holding(_ test: String) -> TestPlan? {
        guard let module = Self.module(of: test) else { return nil }
        return plans.first { $0.module == module }
    }
}
