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

    /// A project's own mutants that had nothing to anchor to, by file.
    ///
    /// Carried all the way out because a row that stopped applying is a measurement
    /// silently not taken - the same failure as an expectation naming a mutant that no
    /// longer exists, and it fails a run for the same reason.
    public let unanchored: [(path: WorkspaceRelativePath, mutant: UnanchoredMutant)]

    /// How many files were read.
    public let filesRead: Int

    /// A digest of every file the package has, mutable or not.
    ///
    /// Every file, including the tests, and that breadth is the point. An outcome may be
    /// remembered between runs only if everything it rests on is unchanged, and what a test
    /// concludes rests on the test as much as on the code - a cache that watched only the
    /// files it could mutate would answer `survived` for a mutant somebody had just written
    /// a test for. A file this has no digest for makes the mutants near it uncacheable
    /// rather than wrongly cached.
    public let digests: [WorkspaceRelativePath: Digest]

    /// The same listing, holding only the files that pass `isKept`.
    ///
    /// The catalogue is rebuilt rather than filtered in place, because a catalogue checks
    /// that no two mutants share a display prefix - and a smaller catalogue is a different
    /// question with a different answer.
    public func keeping(_ isKept: (WorkspaceRelativePath) -> Bool) -> Self {
        Self(
            catalog: (try? Catalog(catalog.mutants.filter { isKept($0.path) }))
                ?? catalog,
            skips: skips.filter { isKept($0.path) },
            unknownSuppressions: unknownSuppressions.filter { isKept($0.path) },
            positions: positions.filter { isKept($0.key) },
            // Every one, whatever the scope. A run narrowed to four files still has to say
            // that a row somewhere else stopped applying: narrowing what is measured does
            // not narrow what a project wrote down.
            unanchored: unanchored,
            filesRead: filesRead,
            // Every file, still: narrowing what is *measured* does not narrow what the
            // answers rest on. A run scoped to four files is still wrong if a fifth one
            // changed under it.
            digests: digests
        )
    }

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

    /// One of a package's files, and whether a mutant may be put in it.
    ///
    /// A target holding C is a `library` like any other, so its `.c` files arrive here too.
    /// They are digested and not parsed - swift-syntax reads `#define` and `#include` as
    /// macro expansions, which this tool skips, so a package vendoring a C dependency once
    /// got a per-line `macro-expansion` skip for somebody else's preprocessor, reported as
    /// a finding about their code.
    struct Subject: Sendable {
        let path: WorkspaceRelativePath
        let isMutable: Bool
    }

    /// What one file contributed.
    ///
    /// A `discovery` of nothing is not the same as no discovery: the first means a Swift
    /// file this tool read and found nothing in, and `nil` means a file it only digested -
    /// a test, a C source, one the selection excluded. Both are counted in the digest,
    /// because what a test concludes rests on the test as much as on the code and an
    /// answer remembered between runs has to rest on all of it. Only the first is a file
    /// read.
    struct Read: Sendable {
        let path: WorkspaceRelativePath
        let digest: Digest
        let discovery: FileDiscovery?
        let positions: LineIndex?
    }

    /// Reads one file and finds what is in it, or nothing when it cannot be read at all.
    ///
    /// Static and given everything it needs, so that it is work rather than a step: nothing
    /// here touches what another file produced, which is what lets the files be read at
    /// once and what makes this testable without a package to point it at.
    static func reading(
        _ subject: Subject,
        in root: URL,
        admitted selection: GlobSet,
        as configuration: Configuration
    ) -> Read? {
        guard
            let source = try? String(
                contentsOf: root.appending(path: subject.path.rendered), encoding: .utf8)
        else { return nil }

        let digest = Digest.of(source)
        guard subject.isMutable, subject.path.isSwift, selection.admits(subject.path) else {
            return Read(path: subject.path, digest: digest, discovery: nil, positions: nil)
        }
        return Read(
            path: subject.path,
            digest: digest,
            discovery: Discover.candidates(
                in: source,
                at: subject.path,
                custom: Self.own(of: subject.path, in: configuration)),
            positions: LineIndex(source)
        )
    }

    /// The mutants this project wrote for itself that name this file.
    ///
    /// Matched on the path the repository uses, which is how a project writes one down and
    /// how every other part of this tool names a file. A row naming a file the package does
    /// not have is nobody's file and is caught where the run accounts for its rows, not
    /// here - discovery reads one file and cannot know what the package holds.
    static func own(
        of path: WorkspaceRelativePath, in configuration: Configuration
    ) -> [CustomMutant] {
        configuration.mutation.custom
            .filter { $0.file == path.rendered }
            .map {
                CustomMutant(find: $0.find, replace: $0.replace, reason: $0.reason, line: $0.line)
            }
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

        // Flattened before anything is read, so that the work is a list and the answers
        // come back where they went in. Reading and parsing a file is work no other file's
        // work depends on - three passes over every byte, a full-fidelity parse, an
        // operator fold and a walk - and doing it one file at a time leaves every core but
        // one idle through the whole of the command people reach for *because* it is the
        // fast one.
        //
        // Bounded by what the machine has rather than by `--jobs`. That knob is about how
        // many processes may be running, and a process is bounded by its memory; this is
        // work inside one process bounded by cores, and the two questions have different
        // right answers.
        let subjects = description.targets.flatMap { target in
            target.sources.map { Subject(path: $0, isMutable: target.kind.isMutable) }
        }
        let found = await WorkerPool(jobs: ProcessInfo.processInfo.activeProcessorCount)
            .run(over: subjects) { subject, _ in
                Self.reading(subject, in: root, admitted: selection, as: configuration)
            }

        var mutants: [Mutant] = []
        var skips: [(path: WorkspaceRelativePath, skip: Skip)] = []
        var unknown: [(path: WorkspaceRelativePath, suppression: UnknownSuppression)] = []
        var unanchored: [(path: WorkspaceRelativePath, mutant: UnanchoredMutant)] = []
        var positions: [WorkspaceRelativePath: LineIndex] = [:]
        var digests: [WorkspaceRelativePath: Digest] = [:]
        var filesRead = 0

        // Merged in the order the files were given, never the order they finished. A
        // catalogue that changed shape because a machine was busy could not be diffed
        // against yesterday's, and a mutant's position in it is part of what a shard is.
        for read in found {
            guard let read else { continue }
            digests[read.path] = read.digest
            guard let discovery = read.discovery else { continue }
            filesRead += 1
            positions[read.path] = read.positions
            for skip in discovery.skips { skips.append((read.path, skip)) }
            for stale in discovery.unanchored { unanchored.append((read.path, stale)) }
            for suppression in discovery.unknownSuppressions {
                unknown.append((read.path, suppression))
            }
            mutants += Self.mutants(of: discovery, at: read.path)
        }

        return Listing(
            catalog: try Catalog(mutants),
            skips: skips,
            unknownSuppressions: unknown,
            positions: positions,
            unanchored: unanchored,
            filesRead: filesRead,
            digests: digests
        )
    }
}
