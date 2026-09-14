// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCache
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsExecute

/// Asking each test what it reaches, and not asking the ones that already answered.
///
/// The probe is one process per test, and a process launch costs about what a handful of
/// tests cost - several hundred launches on a package of any size. What a test runs changes
/// only when the code it runs changes, and that is a question this tool can already answer,
/// so most of those launches are rediscovering something that did not move.
extension Run {

    /// What each test was seen to run last time, if this run may believe any of it.
    func recalled(_ observable: [WorkspaceRelativePath], _ listing: Listing) -> ProbeMemory {
        let empty = ProbeMemory(
            toolVersion: ToolIdentity.current, observable: observable, digests: listing.digests)
        guard configuration.cache.mode != .disabled else { return empty }
        return ProbeMemory.read(from: ProbeMemory.location(for: root), asOf: ToolIdentity.current)
    }

    /// One coverage map out of what was remembered and what had to be asked.
    ///
    /// A test whose probe could not be trusted is not remembered: nothing was established
    /// about it, and writing down nothing as though it were an answer is how a mutant the
    /// test catches every day becomes a survivor nobody looks at.
    static func merged(
        remembered: [String: Set<UInt32>],
        asked: Coverage?,
        tests: [String]
    ) -> Coverage {
        var reach = remembered
        for (test, indices) in asked?.reach ?? [:] { reach[test] = indices }

        var byMutant: [UInt32: [String]] = [:]
        for test in tests {
            for index in (reach[test] ?? []).sorted() { byMutant[index, default: []].append(test) }
        }
        return Coverage(
            byMutant: byMutant,
            tests: tests,
            reach: reach,
            untrusted: asked?.untrusted ?? []
        )
    }

    /// Writes down what every test was seen to run, for the next run.
    ///
    /// Built fresh rather than added to, so that a test the suite no longer has leaves the
    /// memory with it - a memory that only ever grew would answer about tests nobody has.
    func remember(
        _ coverage: Coverage,
        observable: [WorkspaceRelativePath],
        catalogue: MutantCatalogue,
        listing: Listing
    ) {
        guard configuration.cache.mode != .disabled else { return }
        try? Self.memory(
            of: coverage, observable: observable, catalogue: catalogue, digests: listing.digests
        ).write(to: ProbeMemory.location(for: root))
    }

    /// What this run would have the next one believe.
    ///
    /// A test whose probe could not be trusted is left out. Nothing was established about
    /// it, and writing down nothing as though it were an answer is how a mutant the test
    /// catches every day becomes a survivor nobody looks at - the same mistake an empty
    /// reach set is, one run further on and much harder to see.
    static func memory(
        of coverage: Coverage,
        observable: [WorkspaceRelativePath],
        catalogue: MutantCatalogue,
        digests: [WorkspaceRelativePath: Digest]
    ) -> ProbeMemory {
        var memory = ProbeMemory(
            toolVersion: ToolIdentity.current, observable: observable, digests: digests)
        let untrusted = Set(coverage.untrusted)
        for (test, indices) in coverage.reach where !untrusted.contains(test) {
            memory = memory.recording(
                test,
                ran: Array(Set(indices.compactMap { catalogue.files[$0] })),
                reaching: indices.compactMap { catalogue.identities[$0]?.digest },
                digests: digests
            )
        }
        return memory
    }
}
