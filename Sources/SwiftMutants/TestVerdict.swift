// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

enum TestInventory: String, Sendable, CaseIterable {
    case empty, changed, matched
}

enum TestVerdict: String, Sendable, CaseIterable {
    case killed, survived, timedOut, invalidEvidence, noTests, changedTests

    static func classify(
        timedOut: Bool,
        trustworthy: Bool,
        inventory: TestInventory,
        failed: Bool
    ) -> Self {
        if timedOut { return .timedOut }
        guard trustworthy else { return .invalidEvidence }
        switch inventory {
        case .empty: return .noTests
        case .changed: return .changedTests
        case .matched: return failed ? .killed : .survived
        }
    }

    var outcome: MutationOutcome {
        switch self {
        case .killed: .killed
        case .survived: .survived
        case .timedOut: .timedOut
        case .invalidEvidence, .noTests, .changedTests: .errored
        }
    }

    var diagnostic: String? {
        switch self {
        case .killed, .survived: nil
        case .timedOut: "The selected tests exceeded their deadline."
        case .invalidEvidence: "Test execution didn't produce trustworthy results."
        case .noTests: "The selected suite executed no tests."
        case .changedTests: "The mutant changed which tests executed or were skipped."
        }
    }
}
