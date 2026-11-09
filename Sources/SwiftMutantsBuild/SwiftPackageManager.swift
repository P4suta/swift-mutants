// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import SwiftMutantsCore
public import SwiftMutantsRunner

/// Reads package-owned targets through SwiftPM's description command.
package struct SwiftPackageManager: Sendable {
    let root: URL
    let runner: Runner
    let executable: String

    package init(root: URL, runner: Runner, executable: String = "/usr/bin/env") {
        self.root = root
        self.runner = runner
        self.executable = executable
    }

    package func describe(environment: [String: String]) async throws -> WorkspaceDescription {
        let result = await runner.run(
            ProcessSpec(
                kind: .describe,
                executable: executable,
                arguments: ["swift", "package", "describe", "--type", "json"],
                directory: root.path,
                environment: environment,
                timeout: .seconds(120)
            )
        )
        try Task.checkCancellation()
        guard result.startFailure == nil, !result.timedOut, result.exitCode == 0,
            !result.standardOutputWasCut
        else {
            throw BuildSystemError(
                "Package description failed: \(result.startFailure ?? result.standardErrorText)"
            )
        }
        return try Self.decode(result.standardOutput, root: root)
    }

    static func decode(_ bytes: [UInt8], root: URL) throws -> WorkspaceDescription {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let described = try JSONDecoder().decode(Described.self, from: Data(bytes))
        for dependency in described.dependencies {
            if let path = dependency.path {
                let resolved =
                    (path.hasPrefix("/") ? URL(filePath: path) : root.appending(path: path))
                    .standardizedFileURL.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(root.path + "/") else {
                    throw BuildSystemError("Local dependency is outside the package: \(path)")
                }
            }
        }
        let targets = try described.targets.map { target in
            let targetRoot =
                (target.path.hasPrefix("/")
                ? URL(filePath: target.path) : root.appending(path: target.path))
                .standardizedFileURL.resolvingSymlinksInPath()
            guard targetRoot.path == root.path || targetRoot.path.hasPrefix(root.path + "/") else {
                throw BuildSystemError("Target is outside the package: \(target.path)")
            }
            let sources = try target.sources.map { name in
                let file = targetRoot.appending(path: name).standardizedFileURL
                guard file.path.hasPrefix(root.path + "/"),
                    let path = WorkspaceRelativePath(
                        String(file.path.dropFirst(root.path.count + 1))
                    )
                else { throw BuildSystemError("Source is outside the package: \(name)") }
                return path
            }
            return WorkspaceDescription.Target(
                name: target.name,
                kind: WorkspaceDescription.Kind(rawValue: target.type) ?? .system,
                sources: sources
            )
        }
        return WorkspaceDescription(name: described.name, targets: targets)
    }
}

private struct Described: Decodable {
    let name: String
    let targets: [DescribedTarget]
    let dependencies: [DescribedDependency]
}

private struct DescribedTarget: Decodable {
    let name: String
    let type: String
    let path: String
    let sources: [String]
}

private struct DescribedDependency: Decodable {
    let path: String?
}
