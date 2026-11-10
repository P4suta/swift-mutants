// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsBuild
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsRunner
import SwiftMutantsSnapshot

extension MeasurementSession {
    func discover() async throws -> [MutationSource] {
        try await verifyToolchain()
        progress(.stage(.discovery))
        do {
            let description = try await SwiftPackageManager(
                root: snapshot.root,
                runner: runner,
                executable: executable
            ).describe(environment: environment)
            try rejectUITests(description)
            let scope = GlobSet(
                include: options.include.compactMap(Glob.init),
                exclude: options.exclude.compactMap(Glob.init))
            let paths = Set(description.mutableTargets.flatMap(\.sources)).sorted().filter { path in
                path.isSwift && scope.admits(path)
            }
            return try paths.map(readSource)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as MutationTestingError {
            throw failure
        } catch {
            throw MutationTestingError(stage: .discovery, diagnostic: "\(error)")
        }
    }

    private func verifyToolchain() async throws {
        progress(.stage(.toolchain))
        let version = try await command(["--version"], kind: .versionProbe, timeout: .seconds(30))
        try requireSuccess(version, stage: .toolchain)
        guard let match = version.standardOutputText.firstMatch(of: /Swift version (\d+)\.(\d+)/),
            let major = Int(match.1), let minor = Int(match.2),
            major > 6 || (major == 6 && minor >= 3)
        else {
            throw MutationTestingError(
                stage: .toolchain,
                diagnostic: "Swift 6.3 or later is required.\n\(version.standardOutputText)"
            )
        }
    }

    private func rejectUITests(_ description: WorkspaceDescription) throws {
        for target in description.targets where target.kind == .test {
            for path in target.sources where path.isSwift {
                let source = try readSourceText(path)
                if source.contains("XCUIApplication(") || source.contains("import XCUIAutomation") {
                    throw MutationTestingError(
                        stage: .input,
                        diagnostic: "UI tests aren't supported: \(path)"
                    )
                }
            }
        }
    }

    private func readSource(_ path: WorkspaceRelativePath) throws -> MutationSource {
        let source = try readSourceText(path)
        let discovery = Discover.candidates(in: source, at: path)
        let mutations = try Mutation.discover(in: source, at: path.rendered)
        return MutationSource(
            path: path.rendered,
            source: source,
            discovery: discovery,
            mutations: mutations
        )
    }

    func readSourceText(_ path: WorkspaceRelativePath) throws -> String {
        let bytes = try Data(contentsOf: snapshot.root.appending(path: path.rendered))
        guard let source = String(validating: bytes, as: UTF8.self) else {
            throw MutationTestingError(
                stage: .discovery, diagnostic: "Source isn't valid UTF-8: \(path.rendered)")
        }
        return source
    }
}
