// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsExecute
import SwiftMutantsReport

extension Ledger {

    /// One decided mutant, in the form a ledger keeps.
    ///
    /// Deliberately less than a report's row. A report carries positions, the text either
    /// side of the edit and what reached it; every one of those is a field that could fail
    /// to encode while a run is being killed, which is the one moment this has to work.
    /// What somebody reading an interrupted run needs first is which mutant, where, and
    /// what happened to it.
    static func answer(for result: MutantResult) -> Answer {
        Answer(
            identity: result.identity.rendered,
            path: result.path.rendered,
            rule: result.rule.rendered,
            outcome: result.verdict.outcome.rawValue,
            killedBy: result.verdict.killedBy,
            durationMilliseconds: result.verdict.durationMilliseconds
        )
    }
}
