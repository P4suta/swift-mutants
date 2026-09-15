// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsBuild

/// A package builds one test bundle per test target, and a mutant faces the ones that
/// could catch it.
///
/// This was one bundle for the whole package, and the design said so out loud: coverage
/// narrowing was "test by test" because there was nothing coarser to narrow by. SwiftPM's
/// build system changed it - measured here, thirty bundles where there had been one - and
/// the tool refused to run at all rather than pick between them, which was the right
/// refusal and not a workable answer.
///
/// A test names its bundle: swift-testing identifies a test as `Module.Suite/name()`, and
/// the module of a test target is the bundle it is built into. So the tests a probe says
/// reach a mutant also say which bundles that mutant has to be offered to - usually one,
/// and never all of them once coverage is known.
@Suite("Test bundles")
struct TestBundleTests {

    static func plan(_ module: String) -> TestPlan {
        TestPlan(
            executable: "/helper",
            arguments: ["--test-bundle-path", "/build/\(module).xctest"],
            environment: [:],
            directory: "/pkg",
            module: module
        )
    }

    static let bundles = TestBundles(plans: [
        Self.plan("AppTests"), Self.plan("CoreTests"), Self.plan("NetTests"),
    ])

    @Test("offers a mutant only the bundles holding the tests that reach it")
    func narrowsToTheBundlesThatMatter() {
        let chosen = Self.bundles.covering(["CoreTests.Spans/holds()", "CoreTests.Spans/ends()"])
        #expect(chosen.map(\.module) == ["CoreTests"])
    }

    @Test("offers every bundle the tests span")
    func spansSeveralBundles() {
        let chosen = Self.bundles.covering(["NetTests.Client/gets()", "AppTests.Main/runs()"])
        // In the bundles' own order, so two runs of the same package run them the same way.
        #expect(chosen.map(\.module) == ["AppTests", "NetTests"])
    }

    /// Nothing known about which tests matter means every test might be the one that
    /// notices, which is exactly what a run without coverage has to assume.
    @Test("offers every bundle when nothing is known about which tests matter")
    func offersEverythingWithoutCoverage() {
        #expect(Self.bundles.covering(nil).map(\.module) == ["AppTests", "CoreTests", "NetTests"])
    }

    /// A test whose bundle is not in the plan is a test this cannot run, and dropping it
    /// silently would be answering a mutant with a suite that never included its killer.
    /// Offering everything is the direction to be wrong in.
    @Test("offers every bundle when a test names one it does not have")
    func unknownBundleWidensRatherThanNarrows() {
        let chosen = Self.bundles.covering(["GhostTests.Thing/does()"])
        #expect(chosen.map(\.module) == ["AppTests", "CoreTests", "NetTests"])
    }

    /// An empty list is not the same as no list. "These tests, and there are none of them"
    /// is a mutant nothing reaches, and the caller answers that without a process at all -
    /// so reaching here with one is a bug, and running the whole suite is the safe reading.
    @Test("offers every bundle for an empty list of tests")
    func emptyListWidens() {
        #expect(Self.bundles.covering([]).map(\.module).count == 3)
    }

    /// The shapes swift-testing actually emits: `Module.Suite/name()` for a test in a
    /// suite, `Module.name()` for one that stands alone. Both were read off a real event
    /// stream rather than imagined, which is the only way to be sure - the first version of
    /// this test asserted a shape nothing produces.
    @Test(
        "reads the bundle out of a test's name",
        arguments: [
            ("CoreTests.Spans/holds()", "CoreTests"),
            ("CoreTests.boundary()", "CoreTests"),
            ("CoreTests.A.B/holds()", "CoreTests"),
            ("CoreTests.Spans/holds()/Spans.swift:7:6", "CoreTests"),
        ])
    func readsTheModule(named: String, module: String) {
        #expect(TestBundles.module(of: named) == module)
    }

    /// A name with no module in front of it belongs to no bundle this knows, and the
    /// answer is to widen rather than to guess. `CoreTests/holds()` is here rather than
    /// above because nothing emits it: a name whose first separator is a slash has no
    /// module part, and inventing one would place a test in a bundle on a hunch.
    @Test(
        "reads no bundle out of a name that has none",
        arguments: ["holds()", "", "/holds()", "CoreTests/holds()"])
    func readsNoModule(named: String) {
        #expect(TestBundles.module(of: named) == nil)
    }
}
