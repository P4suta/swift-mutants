// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCache
import SwiftMutantsReport
import Testing

@testable import SwiftMutantsCLI

/// Everything this tool keeps about one package.
///
/// The failure this guards is silent and certain: somebody adds a fourth thing the tool
/// keeps - a ledger of answers, say - wires it into a run, and `cache clean` goes on
/// forgetting three of them. What is left behind is a file nobody asked for, outliving the
/// command that exists to remove it, and nothing says so.
///
/// It is the same shape as the configuration gate: the mistake is never getting the removal
/// wrong, it is not knowing there is a fourth thing.
@Suite("What is kept about a package")
struct KeptFilesTests {

    static let package = URL(filePath: "/tmp/somebody/their-package")

    static func kept() -> Set<URL> {
        Set(CacheCommand.kept(for: Self.package).map(\.standardizedFileURL))
    }

    @Test("names every place a run writes")
    func namesEveryPlace() {
        // Named one at a time rather than counted, because a count agrees with itself
        // after somebody swaps one for another.
        let wanted = [
            OutcomeCache.location(for: Self.package),
            ProbeMemory.location(for: Self.package),
            ReportStore.location(for: Self.package),
            Ledger.location(for: Self.package),
        ]
        for file in wanted {
            #expect(Self.kept().contains(file.standardizedFileURL), "\(file.lastPathComponent)")
        }
    }

    /// And nothing else. A `clean` that removed a file belonging to another package, or
    /// something that is not this tool's at all, would be far worse than one that left a
    /// file behind.
    @Test("names nothing outside this tool's own directory")
    func nothingElse() {
        let home = CacheInventory.home().standardizedFileURL.path
        for file in Self.kept() {
            #expect(file.deletingLastPathComponent().path == home, "\(file.path)")
        }
    }

    /// Keyed by the package, so clearing one package's answers does not clear another's.
    @Test("keeps two packages apart")
    func twoPackages() {
        let other = Set(
            CacheCommand.kept(for: URL(filePath: "/tmp/somebody/else")).map(\.standardizedFileURL))
        #expect(Self.kept().isDisjoint(with: other))
    }
}
