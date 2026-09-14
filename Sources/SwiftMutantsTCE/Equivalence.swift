// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore

/// What a set of fingerprints says.
///
/// Once every survivor has been compiled and hashed, two things fall out at once.
///
/// A mutant whose program is the original's cannot be caught by anything, ever. Reporting
/// it as a survivor is telling somebody their tests have a hole where there is no hole, and
/// they will go and look - which is the most expensive kind of wrong a mutation tool can be.
///
/// And two mutants whose programs are each other's are one finding written twice. Somebody
/// reads the same line of code four times and writes the same assertion four times, or
/// gives up on the report.
///
/// Both are answers about the code rather than about the tests, which is why they are worth
/// having: no amount of test-writing changes either.
public struct Equivalence: Sendable, Hashable {

    /// Mutants the compiler turned into the original program.
    public let equivalent: Set<UInt32>

    /// Mutants that are another mutant again, pointing at the one that keeps its place.
    ///
    /// The lowest index of a group is the one that keeps it, so two runs of the same
    /// package point the same way.
    public let duplicates: [UInt32: UInt32]

    /// Reads a set of fingerprints against the original's.
    public init(of fingerprints: [UInt32: Digest], matching original: Digest) {
        var equivalent: Set<UInt32> = []
        var byFingerprint: [Digest: [UInt32]] = [:]
        for (index, fingerprint) in fingerprints {
            if fingerprint == original {
                equivalent.insert(index)
                continue
            }
            byFingerprint[fingerprint, default: []].append(index)
        }

        var duplicates: [UInt32: UInt32] = [:]
        for group in byFingerprint.values where group.count > 1 {
            let kept = group.min() ?? group[0]
            for index in group where index != kept { duplicates[index] = kept }
        }

        self.equivalent = equivalent
        self.duplicates = duplicates
    }
}
