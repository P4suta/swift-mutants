// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsExecute

/// The deadline, once it is no longer the limit.
///
/// A budget used to decide with the clock, and that made every verdict sensitive to how busy
/// the machine was. Both of its terms were measured once at the start, so a machine that got
/// busier afterwards made all of them underestimates: a baseline of 898 seconds became 1767
/// because a build started in another window, mutants met deadlines they should not have,
/// were retried, met them again, and were recorded as detections.
///
/// The answer was not to notice the drift. It was to decide with something that does not
/// drift - the work a mutant does - and to leave the clock in place for the one thing an
/// allowance cannot see, because waiting is not working and a deadlock spends no processor
/// at all.
///
/// Which means the deadline must now be *generous*. It is not deciding anything a healthy
/// trial could trip over; it only has to be finite, so that a mutant which waits forever
/// ends. A deadline still tuned to be the limit would go on producing exactly the false
/// detections the allowance was introduced to remove.
@Suite("The deadline, as a backstop")
struct BackstopTests {

    static func measured(cpu: Int?) -> Budget {
        .deriving(
            suiteMilliseconds: 10_000,
            tests: 100,
            oneTestMilliseconds: 100,
            cpuSuiteMilliseconds: cpu,
            cpuOneTestMilliseconds: cpu.map { _ in 20 }
        )
    }

    /// Far past what the work itself is allowed, because a trial that has not spent its
    /// allowance is a trial that is working - slowly, on a machine somebody else is using.
    @Test("is far longer than the work a trial is allowed")
    func farPastTheAllowance() {
        let budget = Self.measured(cpu: 4_000)
        guard let deadline = Optional(budget.forTrial(bundles: 1, tests: 20)),
            let allowance = budget.cpuForTrial(bundles: 1, tests: 20)
        else {
            Issue.record("a measured suite produced no allowance")
            return
        }
        #expect(deadline > allowance * 10, "\(deadline) against \(allowance)")
    }

    /// And never shorter than it was. A run with no allowance is a run the clock still
    /// decides, and shortening the deadline there would be tightening the only limit left.
    @Test("is never shorter than the deadline a run without an allowance gets")
    func neverTighter() {
        let withWork = Self.measured(cpu: 4_000).forTrial(bundles: 1, tests: 20)
        let without = Self.measured(cpu: nil).forTrial(bundles: 1, tests: 20)
        #expect(withWork >= without, "\(withWork) is shorter than \(without)")
    }

    /// An explicit deadline is an answer, and stays exactly what was asked for. Somebody
    /// who wrote `--timeout 90` gets ninety seconds, not ninety times anything.
    @Test("is exactly what was asked for when somebody asked")
    func explicitIsExact() {
        #expect(Budget.flat(.seconds(90)).forTrial(bundles: 1, tests: 20) == .seconds(90))
    }
}
