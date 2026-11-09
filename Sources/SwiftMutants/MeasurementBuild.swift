// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsRunner
import SwiftMutantsSnapshot

extension MeasurementSession {
    func build(_ kind: BuildKind, timeout: Duration) async throws -> ProcessOutcome {
        progress(.stage(.build))
        progress(.building(kind))
        return try await command(["build", "--build-tests"], kind: .build, timeout: timeout)
    }

    func products() async throws -> [TestProduct] {
        let result = try await command(
            ["build", "--show-bin-path"],
            kind: .describe,
            timeout: .seconds(30)
        )
        try requireSuccess(result, stage: .build)
        let directory = URL(
            filePath: result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let bundles = try files(in: directory, stage: .build)
            .filter { $0.pathExtension == "xctest" }.sorted { $0.path < $1.path }
        guard !bundles.isEmpty else {
            throw MutationTestingError(
                stage: .build,
                diagnostic: "The package produced no test bundles."
            )
        }
        return try bundles.map { bundle in
            let name = bundle.deletingPathExtension().lastPathComponent
            let binary = bundle.appending(path: "Contents/MacOS/\(name)")
            guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                throw MutationTestingError(
                    stage: .build,
                    diagnostic: "Missing test executable: \(binary.path)"
                )
            }
            return TestProduct(name: name, binary: binary, directory: directory)
        }
    }

    func symbols(in products: [TestProduct], matching tokens: [String]) async throws -> String {
        var found: Set<String> = []
        guard let directory = products.first?.directory else {
            throw MutationTestingError(
                stage: .instrumentation,
                diagnostic: "No test products to inspect."
            )
        }
        let libraries = try files(in: directory, stage: .instrumentation)
            .filter { $0.pathExtension == "dylib" }
            .sorted { $0.path < $1.path }
        for binary in libraries + products.map(\.binary) {
            let result = await runner.run(
                ProcessSpec(
                    kind: .describe,
                    executable: "/usr/bin/nm",
                    arguments: ["--defined-only", "--no-demangle", "-j", binary.path],
                    directory: snapshot.root.path,
                    environment: environment,
                    timeout: .seconds(30)
                ),
                matchingOutput: tokens
            )
            try Task.checkCancellation()
            try requireSuccess(result, stage: .instrumentation)
            found.formUnion(result.matchedOutput)
            if tokens.allSatisfy({ $0.isEmpty || found.contains($0) }) { break }
        }
        return found.sorted().joined(separator: "\n")
    }

    private func files(in directory: URL, stage: RunStage) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch {
            throw MutationTestingError(
                stage: stage,
                diagnostic: "Couldn't read build products in \(directory.path): \(error)"
            )
        }
    }
}

struct TestProduct: Sendable {
    let name: String
    let binary: URL
    let directory: URL
}
