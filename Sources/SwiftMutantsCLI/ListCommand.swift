// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutants

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List source mutations without running tests."
    )
    @OptionGroup var package: PackageArguments

    mutating func run() async throws {
        do {
            try LegacyConfiguration.check(packagePath: package.packagePath)
            let root = URL(filePath: package.packagePath)
            let include = package.include
            let exclude = package.exclude
            let mutations = try await SignalCancellation.run {
                try await MutationTesting.list(packageAt: root, include: include, exclude: exclude)
            }
            if package.json {
                print(try ReportRendering.json(Listing(mutations: mutations)))
            } else {
                for mutation in mutations { print(ReportRendering.mutation(mutation)) }
                print("\(mutations.count) mutations")
            }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            Terminal.error("\(error)")
            throw ExitCode(2)
        }
    }
}

private struct Listing: Encodable {
    let schemaVersion = 3
    let mutations: [Mutation]
}
