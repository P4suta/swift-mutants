// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsExecute

/// A budget in the unit the work is done in.
///
/// Both terms of a budget were measured in wall time, which makes every deadline derived
/// from them a statement about the machine as much as about the suite. A baseline of 898
/// seconds became 1767 because a build started in another window, and every deadline after
/// that point came from the wrong number - so mutants met deadlines they should not have,
/// were retried, met them again, and were recorded as detections.
///
/// The fix is not to notice the drift. It is to measure something that does not drift: a
/// process doing the same work consumes the same processor seconds however busy the machine
/// is. Then the allowance is a statement about the program, the kernel enforces it, and
/// there is nothing to notice.
@Suite("A budget in processor time")
struct WorkBudgetTests {

    static func terms(
        suiteCpu: Int = 10_000, tests: Int = 100, oneTestCpu: Int? = 200
    ) -> Budget {
        .deriving(
            suiteMilliseconds: 60_000,
            tests: tests,
            oneTestMilliseconds: 500,
            cpuSuiteMilliseconds: suiteCpu,
            cpuOneTestMilliseconds: oneTestCpu
        )
    }

    /// A mutant facing a handful of tests is allowed a handful of tests' worth of work,
    /// the same way its deadline is a handful of tests' worth of time.
    @Test("gives a mutant the work of the tests it faces")
    func scalesWithWhatItFaces() {
        let budget = Self.terms()
        guard let few = budget.cpuForTrial(bundles: 1, tests: 5),
            let all = budget.cpuForTrial(bundles: 1, tests: nil)
        else {
            Issue.record("a measured suite produced no allowance")
            return
        }
        #expect(few < all, "\(few) is not less than \(all)")
    }

    /// Room for a machine that is not the one measured, and for a mutant that is merely
    /// slow rather than stuck. Every unknown resolves towards more, for the same reason as
    /// everywhere else: an allowance met is a survivor recorded as a detection, and nobody
    /// ever finds out.
    @Test("leaves room above what the suite itself needs")
    func leavesRoom() {
        #expect((Self.terms().cpuForTrial(bundles: 1, tests: nil) ?? .zero) > .milliseconds(10_000))
    }

    /// Nothing measured is not zero measured. A run whose processor time could not be read
    /// has no allowance to give, and the wall clock is what is left - which is where this
    /// tool was before, rather than a limit of zero that nothing could meet.
    @Test("gives no allowance at all when nothing was measured")
    func nothingMeasured() {
        let budget = Budget.deriving(
            suiteMilliseconds: 60_000,
            tests: 100,
            oneTestMilliseconds: 500,
            cpuSuiteMilliseconds: nil,
            cpuOneTestMilliseconds: nil
        )
        #expect(budget.cpuForTrial(bundles: 1, tests: nil) == nil)
    }

    /// An explicit `--timeout` is an answer rather than an input, and it is an answer about
    /// the clock. Deriving an allowance the person did not ask for and enforcing it in a
    /// different unit would be overruling them in a way they could not see.
    @Test("gives no allowance when a deadline was asked for by name")
    func explicitTimeoutWins() {
        #expect(Budget.flat(.seconds(90)).cpuForTrial(bundles: 1, tests: nil) == nil)
    }

    /// The floor, for the same reason the deadline has one: a suite measured quick for
    /// reasons that say nothing about one mutant - a warm cache, a machine that happened to
    /// be idle - must not produce an allowance a healthy trial cannot meet.
    @Test("never gives less than the floor")
    func theFloor() {
        let budget = Self.terms(suiteCpu: 1, tests: 1, oneTestCpu: 0)
        #expect((budget.cpuForTrial(bundles: 1, tests: 1) ?? .zero) >= Budget.cpuFloor)
    }
}
