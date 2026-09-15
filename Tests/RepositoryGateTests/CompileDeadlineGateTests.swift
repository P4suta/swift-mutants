// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTestKit
import Testing

/// Keeps every compile deadline derived rather than picked.
///
/// A flat half hour for every package alike is wrong in both directions at once: half an
/// hour to notice that a ten-second package has hung, and less than six of its own builds
/// for a package that takes five minutes to build. The second is the worse one - a compile
/// killed part way is a tree reported as refusing mutants it would have accepted, and
/// rejected mutants leave the denominator, so the score goes up.
///
/// The failure this guards against is not getting the derivation wrong. It is somebody
/// needing a timeout at a new call site, reaching for a number, and writing one - which
/// looks reasonable in review and undoes the derivation for that path only. So the gate is
/// about the shape of the code, the way the configuration gate is: the number exists in one
/// place and every deadline comes from there.
@Suite("Every compile deadline is derived")
struct CompileDeadlineGateTests {

    /// Where the flat number is allowed to appear: the one that says what to do when
    /// nothing was measured.
    static let decidesIt = "CompileDeadline.swift"

    /// Durations long enough that they can only be a compile someone gave up guessing at.
    static let guesses = ["seconds(1800)", "seconds(3600)", "minutes(30)"]

    @Test("spells a flat compile timeout in exactly one place")
    func onlyOnePlaceHasTheNumber() throws {
        var offenders: [String] = []
        for file in try RepositoryGate.swiftFiles(under: "Sources") {
            guard file.lastPathComponent != Self.decidesIt else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            // The baseline's own budget is a test budget rather than a compile one: how
            // long somebody's suite may take is a different question from how long
            // compiling their package may take, and it has its own reasoning where it is.
            let lines = text.split(separator: "\n").filter { line in
                Self.guesses.contains { line.contains($0) }
                    && !line.contains("calibrationBudget")
            }
            if !lines.isEmpty { offenders.append(file.lastPathComponent) }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.joined(separator: ", ")) names a flat compile timeout. Every one \
            comes from CompileDeadline, which derives it from what building this package \
            actually cost - a number written here is right for one machine and one package \
            and wrong everywhere else, in the direction that loses mutants.
            """
        )
    }
}
