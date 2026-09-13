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
    public func describe(
        environment: [String: String] = [:],
        timeout: Duration? = .seconds(120)
    ) async throws(BuildSystemError) -> WorkspaceDescription {
        let outcome = await runner.run(
            ProcessSpec(
                kind: .describe,
                executable: executable,
                arguments: ["package", "describe", "--type", "json"],
                directory: root.path,
                environment: environment,
                timeout: timeout
            )
        )
        if let failure = outcome.startFailure {
            throw BuildSystemError("cannot run \(executable): \(failure)")
        }
        guard outcome.exitCode == 0 else {
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
