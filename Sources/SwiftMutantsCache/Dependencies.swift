// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore

/// Which files a mutant's answer rests on.
///
/// The probe already knows most of it. It records which guards each test evaluated, and
/// every guard is in a file, so the files a test runs are observed rather than guessed -
/// which is what makes a cache worth having at all. Change one corner of a package and only
/// the mutants whose tests go near it have to be measured again.
///
/// What cannot be observed is added to every key rather than left out. A file with no
/// mutants in it has no guards, so nothing can be seen about it; every test file is of that
/// kind, and what a test concludes rests on the test as much as on the code. Those digests
/// are part of every mutant's dependency set, so changing any of them asks every question
/// again.
///
/// The one thing this assumes is that a test which executes a file evaluates a guard in it.
/// Under the default profile nearly every executable statement is a mutation site, so a
/// test that runs a function runs a guard. The exception is a region where every statement
/// was suppressed - a function that only logs, say - and a test that executed such a region
/// of a changed file and nothing else would keep an answer it should have asked again. That
/// is the boundary of what the probe can see, and it is written down here rather than
/// discovered later.
public enum Dependencies {

    /// The digests each mutant's answer rests on, by mutant index.
    ///
    /// A mutant is absent from the result when anything it rests on has no digest - it is
    /// then uncacheable rather than cached against a dependency set that quietly omits
    /// something. Being slow is recoverable and being wrong is not.
    ///
    /// - Parameters:
    ///   - reach: which mutants each test was seen to evaluate a guard for.
    ///   - covering: which tests reach each mutant.
    ///   - files: which file each mutant is in.
    ///   - digests: a digest of every file the package has, mutable or not.
    /// - Returns: the digests each mutant rests on, without the mutants it cannot answer
    ///   for.
    public static func map(
        reach: [String: Set<UInt32>],
        covering: [UInt32: [String]],
        files: [UInt32: WorkspaceRelativePath],
        digests: [WorkspaceRelativePath: Digest]
    ) -> [UInt32: [Digest]] {
        // What the probe can see nothing about, and what therefore belongs to every answer.
        let observable = Set(files.values)
        guard observable.allSatisfy({ digests[$0] != nil }) else { return [:] }
        let remainder = digests.filter { !observable.contains($0.key) }.values

        // Each test's files, worked out once rather than once per mutant that names it.
        var filesRun: [String: Set<WorkspaceRelativePath>] = [:]
        for (test, indices) in reach {
            filesRun[test] = Set(indices.compactMap { files[$0] })
        }

        var found: [UInt32: [Digest]] = [:]
        for index in files.keys {
            var rested: Set<WorkspaceRelativePath> = []
            for test in covering[index] ?? [] { rested.formUnion(filesRun[test] ?? []) }
            let named = rested.compactMap { digests[$0] }
            guard named.count == rested.count else { continue }
            found[index] = named + remainder
        }
        return found
    }
}
