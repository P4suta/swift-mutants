// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutants

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Measure source mutations with existing package tests."
    )
    @OptionGroup var package: PackageArguments

    @Option(
        name: .customLong("mutant"),
        help: "Measure one full mutation ID; repeat to select more mutations."
    )
    var mutantIDs: [String] = []

    @Option(help: "Deadline in seconds for each baseline and mutant, excluding builds.")
    var timeout: Double?

    @Option(help: "Run tests matching a SwiftPM regular expression; repeat to include more tests.")
    var filter: [String] = []

    @Option(help: "Skip tests matching a SwiftPM regular expression; repeat to skip more tests.")
    var skip: [String] = []

    @Flag(help: "Exit 1 when a complete measurement has surviving mutations.")
    var strict = false

    func validate() throws {
        if let timeout, !timeout.isFinite || timeout <= 0 || timeout > Double(Int64.max / 1000) {
            throw ValidationError("The timeout must be a finite positive number of seconds.")
        }
    }

    mutating func run() async throws {
        let root = URL(filePath: package.packagePath)
        let options = RunOptions(
            include: package.include,
            exclude: package.exclude,
            filter: filter,
            skip: skip,
            timeout: timeout.map { .seconds($0) },
            mutantIDs: mutantIDs
        )
        do {
            try LegacyConfiguration.check(packagePath: package.packagePath)
            let report = try await SignalCancellation.run {
                try await MutationTesting.run(packageAt: root, options: options) { event in
                    if let line = ReportRendering.progress(event) { Terminal.error(line) }
                }
            }
            print(package.json ? try ReportRendering.json(report) : ReportRendering.report(report))
            let status = ReportRendering.status(report, strict: strict)
            if status != 0 { throw ExitCode(status) }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            Terminal.error("\(error)")
            throw ExitCode(2)
        }
    }
}
