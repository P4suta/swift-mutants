// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftSyntax

/// Code no test could reasonably assert on.
///
/// This is the highest-yield idea in the whole tool, and the measurement is not subtle.
/// Google ran mutation testing across a two-billion-line repository for six years; adding
/// suppression of this kind took the median number of mutants surfaced for one change from
/// 820 to 7, and the proportion developers called useful from 15% to 89%. The single rule
/// with the most suppressions was fuzzy matching on call names, and logging was the biggest
/// part of it.
///
/// Matching is on the *name* rather than on any resolved symbol, because discovery has no
/// type information and because a project that calls its logger `logger` means it. The
/// failure mode of a false match is a mutant that is not produced, which is the direction
/// to err in: the alternative is a survivor nobody can act on, and a survivor nobody can
/// act on is what makes a team switch the tool off.
enum AridRules {

    /// Functions whose arguments nobody asserts on.
    static let aridFunctions: Set<String> = [
        "print", "debugPrint", "dump", "NSLog",
        "assert", "assertionFailure", "precondition", "preconditionFailure", "fatalError",
    ]

    /// Receivers whose methods nobody asserts on.
    static let aridReceivers: Set<String> = ["logger", "log", "Logger", "os_log", "OSLog"]

    /// Method names that are about capacity or timing rather than about behaviour.
    static let aridMethods: Set<String> = ["reserveCapacity", "sleep", "yield"]

    /// Whether a call is one nothing should be mutated inside.
    static func isArid(_ call: FunctionCallExprSyntax) -> Bool {
        if let identifier = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return aridFunctions.contains(identifier.baseName.text)
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            if aridMethods.contains(member.declName.baseName.text) { return true }
            if let base = member.base?.as(DeclReferenceExprSyntax.self) {
                return aridReceivers.contains(base.baseName.text)
            }
        }
        return false
    }
}
