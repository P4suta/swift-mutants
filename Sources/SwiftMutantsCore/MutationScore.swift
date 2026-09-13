// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// The arithmetic of a run's result.
///
/// Two numbers come out of it rather than one, because a single number is actively
/// misleading. The overall score says how much of the code is protected and cannot
/// distinguish "no test exists" from "the test does not assert". The covered-code score
/// says how good the tests that do exist are. The two failure modes need different fixes -
/// write a test, or write a better assertion - so both are reported and both can be gated
/// on.
public struct MutationScore: Sendable, Hashable {

    /// Mutants the tests noticed: kills plus confirmed timeouts.
    public let detected: Int

    /// Scoreable mutants the tests did not notice, ``uncovered`` among them.
    public let undetected: Int

    /// Undetected mutants that no test reaches at all.
    ///
    /// A subset of ``undetected`` rather than a category beside it, so the columns of a
    /// summary still add up to the number of mutants.
    public let uncovered: Int

    /// Creates a score from a tally that is already known to describe a run.
    ///
    /// Traps on a tally that cannot: a negative count, or more uncovered mutants than
    /// undetected ones. Use ``init(checking:undetected:uncovered:)`` where the numbers come
    /// from outside this process.
    public init(detected: Int, undetected: Int, uncovered: Int) {
        guard
            let score = Self(
                checking: detected, undetected: undetected, uncovered: uncovered)
        else {
            fatalError(
                "detected=\(detected) undetected=\(undetected) uncovered=\(uncovered) does not describe a run"
            )
        }
        self = score
    }

    /// Creates a score, spelling out where the detections came from.
    ///
    /// A confirmed timeout counts as a detection but is always displayed apart from a kill,
    /// which is the caller's business; this type only needs the total.
    public init(killed: Int, confirmedTimeouts: Int, undetected: Int, uncovered: Int) {
        self.init(
            detected: killed + confirmedTimeouts, undetected: undetected, uncovered: uncovered)
    }

    /// Creates a score, or refuses a tally that cannot describe a run.
    public init?(checking detected: Int, undetected: Int, uncovered: Int) {
        guard detected >= 0, undetected >= 0, uncovered >= 0, uncovered <= undetected else {
            return nil
        }
        self.detected = detected
        self.undetected = undetected
        self.uncovered = uncovered
    }

    /// Mutants that were measured and could have gone either way.
    public var valid: Int { detected + undetected }

    /// Mutants at least one test actually reaches.
    public var covered: Int { detected + undetected - uncovered }

    /// Detected over valid, or nothing when nothing scoreable was measured.
    ///
    /// Nothing rather than zero or one. Both sentinels are lies: zero reads as "your tests
    /// caught nothing" and one as "your tests caught everything", when the truth is that
    /// there was nothing to catch.
    public var value: Double? {
        valid == 0 ? nil : Double(detected) / Double(valid)
    }

    /// Detected over covered, or nothing when no mutant was covered.
    public var ofCoveredCode: Double? {
        covered == 0 ? nil : Double(detected) / Double(covered)
    }

    /// ``value`` for a person to read: a percentage to two places, or `N/A`.
    ///
    /// The rounding is for display only. ``value`` keeps full precision, because a report
    /// is also what `report merge` combines and what a threshold is compared against.
    public var rendered: String { Self.render(value) }

    /// ``ofCoveredCode`` for a person to read.
    public var renderedForCoveredCode: String { Self.render(ofCoveredCode) }

    private static func render(_ fraction: Double?) -> String {
        guard let fraction else { return "N/A" }
        let hundredths = (fraction * 10000).rounded()
        let whole = Int(hundredths) / 100
        let remainder = Int(hundredths) % 100
        return "\(whole).\(remainder < 10 ? "0" : "")\(remainder)%"
    }
}
