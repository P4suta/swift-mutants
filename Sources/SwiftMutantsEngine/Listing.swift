// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import SwiftMutantsBuild
public import SwiftMutantsConfig
public import SwiftMutantsCore
public import SwiftMutantsDiscover
public import SwiftMutantsRunner

/// What `swift-mutants list` found.
///
/// Discovery without any of the rest of it: no snapshot, no build, no baseline, no test run.
/// That is deliberate - it is the fast path a person uses to ask "what would you do to my
/// code" before agreeing to let it take an hour, and it is the one command that can answer
/// while the package does not even compile.
public struct Listing: Sendable {

    /// Everything found, in one order, under one digest.
    public let catalog: Catalog

    /// What was passed over, and why, by file.
    public let skips: [(path: WorkspaceRelativePath, skip: Skip)]

    /// Suppression comments that silence nothing, by file.
    ///
    /// Surfaced rather than counted, because each one is somebody believing a mutant was
    /// dealt with when it was not, and the fix is a one-word edit they can only make if
    /// they are told where.
    public let unknownSuppressions: [(path: WorkspaceRelativePath, suppression: UnknownSuppression)]

    /// Where each file's candidates were, for a listing that shows line and column.
    public let positions: [WorkspaceRelativePath: LineIndex]

    /// How many files were read.
    public let filesRead: Int

    /// The files that hold at least one mutant, in catalogue order.
    ///
    /// A file with nothing to mutate is not instrumented, not compiled a second time, and
    /// not part of what a run has to prove. Most of a package is usually this.
    public var filesWithMutants: [WorkspaceRelativePath] {
        var seen: Set<WorkspaceRelativePath> = []
        return catalog.mutants.compactMap { seen.insert($0.path).inserted ? $0.path : nil }
    }
}

/// Runs the `list` pipeline.
public struct Lister: Sendable {

    private let root: URL
    private let configuration: Configuration
    private let runner: Runner
    private let executable: String

    /// Prepares a listing of the package at `root`.
    public init(
        root: URL,
        configuration: Configuration,
        runner: Runner,
        executable: String = "/usr/bin/swift"
    ) {
        self.root = root
        self.configuration = configuration
        self.runner = runner
        self.executable = executable
    }

    /// Turns one file's candidates into mutants, which is where an identity is fixed.
    private static func mutants(
        of discovery: FileDiscovery, at path: WorkspaceRelativePath
    ) -> [Mutant] {
        discovery.candidates.map { candidate in
            Mutant(
                path: path,
                enclosingDeclaration: candidate.enclosingDeclaration,
                rule: candidate.rule,
                span: candidate.span,
                sourceDigest: discovery.sourceDigest,
                original: candidate.original,
                replacement: candidate.replacement
            )
        }
    }

    /// Reads the package, reads its sources, and says what could be mutated.
    ///
    /// The workspace is only ever read. `list` makes no copy because it changes nothing;
    /// every command that does build or run works inside a snapshot instead.
    public func list(environment: [String: String] = [:]) async throws -> Listing {
        let description = try await SwiftPackageManager(
            root: root,
            runner: runner,
            executable: executable
        ).describe(environment: environment)

        let selection = GlobSet(
            include: configuration.mutation.include,
            exclude: configuration.mutation.exclude
        )

        var mutants: [Mutant] = []
        var skips: [(path: WorkspaceRelativePath, skip: Skip)] = []
        var unknown: [(path: WorkspaceRelativePath, suppression: UnknownSuppression)] = []
        var positions: [WorkspaceRelativePath: LineIndex] = [:]
        var filesRead = 0

        for target in description.mutableTargets {
            for path in target.sources where selection.admits(path) {
                guard
                    let source = try? String(
                        contentsOf: root.appending(path: path.rendered),
                        encoding: .utf8
                    )
                else { continue }
                filesRead += 1

                let discovery = Discover.candidates(in: source, at: path)
                positions[path] = LineIndex(source)
                for skip in discovery.skips { skips.append((path, skip)) }
                for suppression in discovery.unknownSuppressions {
                    unknown.append((path, suppression))
                }
                mutants += Self.mutants(of: discovery, at: path)
            }
        }

        return Listing(
            catalog: try Catalog(mutants),
            skips: skips,
            unknownSuppressions: unknown,
            positions: positions,
            filesRead: filesRead
        )
    }
}
