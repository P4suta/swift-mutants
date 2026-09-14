// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsReport

/// A run report built from outcomes, for the tests in this module.
///
/// The report module has its own fixtures and a test target cannot depend on another test
/// target, so this is the same few lines again rather than a dependency that does not
/// exist. It is small on purpose: everything about the report's own shape is settled where
/// the report lives, and what is wanted here is only something to render.
enum ReportFixture {

    static func report(_ results: [(Outcome, [String])]) -> RunReport {
        let mutants = results.map { NarrationFixture.result($0.0, tests: $0.1) }
        return RunReport(
            of: NarrationFixture.outcome(results: mutants),
            positions: NarrationFixture.positions
        )
    }
}
