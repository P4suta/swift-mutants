// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// URL appears in this type's public surface.
public import Foundation
import SwiftMutantsCore
public import SwiftMutantsRunner

/// Asks SwiftPM what a package holds.
///
/// `swift package describe --type json` rather than a directory walk, because a manifest
/// decides what a target contains: it can exclude a file, name its sources explicitly, or
/// put a target in an unexpected place. A tool that globbed would mutate files the package
/// never compiles, producing mutants that can never be killed because nothing runs them -
/// and a score quietly dragged down by them.
public struct SwiftPackageManager: Sendable {

    let root: URL
    let runner: Runner
    let executable: String

    /// Asks about the package at `root`.
    ///
    /// The `swift` to ask is a parameter rather than a constant so that a test can script
    /// one. What this tool does when a toolchain misbehaves is a thing worth testing, and a
    /// `swift` that hangs cannot be installed.
    public init(root: URL, runner: Runner, executable: String = "/usr/bin/swift") {
        self.root = root
        self.runner = runner
        self.executable = executable
    }

    /// Reads the package's description.
    ///
    /// With a scratch directory of its own, because this is not a read. SwiftPM compiles
    /// the manifest to answer, and it lays the result down beside it: a `CACHEDIR.TAG` and
    /// a build-system marker under `.build`, in the tree this tool promises never to write
    /// to. `list` asks this on a tree it never copies, so the promise was being broken by
    /// the one command that makes no copy *because* it changes nothing.
    ///
    /// The directory is outside the package and keyed by where the package is, like the
    /// answers a run remembers. Two packages do not share a manifest cache, and a second
    /// `list` of the same package finds the manifest already compiled.
    public func describe(
        environment: [String: String] = [:],
        timeout: Duration? = .seconds(120)
    ) async throws(BuildSystemError) -> WorkspaceDescription {
        let scratch = Self.manifestScratch(for: root)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let outcome = await runner.run(
            ProcessSpec(
                kind: .describe,
                executable: executable,
                // Before the subcommand. SwiftPM's global options are not accepted after
                // one, and `describe --scratch-path` exits 64 with `Unknown option`.
                arguments: [
                    "package", "--scratch-path", scratch.path, "describe", "--type", "json",
                ],
                directory: root.path,
                environment: environment,
                timeout: timeout
            )
        )
        if let failure = outcome.startFailure {
            throw BuildSystemError("cannot run \(executable): \(failure)")
        }
        guard outcome.exitCode == 0 else {
            // What stopped it first, because a deadline of this tool's own reported as an
            // exit status reads as a fact about somebody's package - and the exit status of
            // a process this tool signalled is a number pointing at the wrong thing.
            if let stopped = outcome.stoppedFromHere(after: timeout) {
                throw BuildSystemError(
                    """
                    `swift package describe` \(stopped) in \(root.path). Nothing is \
                    necessarily wrong with the package: a manifest compiles and then runs, \
                    and a machine with no processor to spare can leave that waiting.
                    """
                )
            }
            let complaint = String(decoding: outcome.standardError, as: UTF8.self)
            throw BuildSystemError(
                """
                `swift package describe` exited \(outcome.exitCode) in \(root.path).
                \(complaint.isEmpty ? "It said nothing." : complaint)
                """
            )
        }
        return try Self.decode(outcome.standardOutput, root: root)
    }

    /// Reads the JSON `swift package describe` prints.
    ///
    /// Separated from running it so that the shape of the document can be tested without a
    /// toolchain, which is where the interesting cases are: a target with no sources, a kind
    /// this build has not been taught, a path outside the package.
    static func decode(_ json: [UInt8], root: URL) throws(BuildSystemError) -> WorkspaceDescription
    {
        let described: Described
        do {
            described = try JSONDecoder().decode(Described.self, from: Data(json))
        } catch {
            throw BuildSystemError(
                """
                `swift package describe --type json` did not answer with a package \
                description: \(error)
                """
            )
        }

        var targets: [WorkspaceDescription.Target] = []
        for target in described.targets {
            // A kind this build has not been taught is not mutated. Guessing would be
            // guessing about whether the code ships.
            let kind = WorkspaceDescription.Kind(rawValue: target.type) ?? .system
            let base = Self.relative(target.path, to: root)
            var sources: [WorkspaceRelativePath] = []
            for source in target.sources {
                let joined = base.isEmpty ? source : "\(base)/\(source)"
                guard let path = WorkspaceRelativePath(joined) else { continue }
                sources.append(path)
            }
            targets.append(
                WorkspaceDescription.Target(name: target.name, kind: kind, sources: sources)
            )
        }
        return WorkspaceDescription(name: described.name, targets: targets)
    }

    /// A target's path as the package describes it, made relative to the root.
    ///
    /// SwiftPM prints an absolute path. An absolute one must never reach a mutant identity,
    /// so it is cut back here rather than anywhere later.
    private static func relative(_ path: String, to root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
    }

}

/// The part of SwiftPM's document this tool reads.
///
/// Only the fields that are needed. A description carries a great deal more, and a decoder
/// that insisted on all of it would break every time SwiftPM added a field.
private struct Described: Decodable {
    let name: String
    let targets: [DescribedTarget]
}

/// One target, as SwiftPM describes it.
private struct DescribedTarget: Decodable {
    let name: String
    let type: String
    let path: String
    let sources: [String]
}

extension SwiftPackageManager {

    /// Where SwiftPM may put what it needs to answer a question about a package.
    ///
    /// Outside the package, for the reason the outcome cache is: a run must not write into
    /// somebody's repository. Keyed by where the package is so that two of them do not
    /// share a manifest cache, and named by a digest so that it is a filename on every
    /// platform and says nothing about the directories it came from.
    public static func manifestScratch(for package: URL) -> URL {
        let root =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let name = DigestBuilder()
            .adding("swift-mutants-manifest")
            .adding(package.standardizedFileURL.path)
            .finalize()
        return
            root
            .appending(path: "swift-mutants")
            .appending(path: "manifests")
            .appending(path: name.hexadecimal)
    }
}
