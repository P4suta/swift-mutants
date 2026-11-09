// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutants

enum ReportRendering {
    static func mutation(_ mutation: Mutation) -> String {
        "\(mutation.path):\(mutation.line):\(mutation.column) \(mutation.id) \(mutation.rule)\n"
            + "  \(String(reflecting: mutation.original)) -> \(String(reflecting: mutation.replacement))"
    }

    static func report(_ report: MutationReport) -> String {
        let survivors = report.results.filter { $0.outcome == .survived }.map {
            mutation($0.mutation)
        }
        let summary = report.summary
        let score =
            report.score.map { value in
                let hundredths = Int((value * 10000).rounded())
                let fraction = hundredths % 100
                return "\(hundredths / 100).\(fraction < 10 ? "0" : "")\(fraction)%"
            } ?? "N/A"
        return
            (survivors + [
                "\(summary.killed) killed, \(summary.survived) survived, \(summary.rejected) rejected, "
                    + "\(summary.timedOut) timed out, \(summary.errored) errored",
                "score \(score)",
            ]).joined(separator: "\n")
    }

    static func status(_ report: MutationReport, strict: Bool) -> Int32 {
        guard report.score != nil else { return 2 }
        return strict && report.summary.survived > 0 ? 1 : 0
    }

    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func progress(_ event: RunEvent) -> String? {
        switch event {
        case .stage: nil
        case .building(.original): "Building the original package"
        case .building(.instrumented): "Building instrumented sources"
        case .building(.individual(let identity)): "Building mutation \(identity)"
        case .baseline(let completed, let total): "Baseline \(completed)/\(total) passed"
        case .measuring(_, let completed, let total): "Measuring mutation \(completed + 1)/\(total)"
        case .measured(let result) where result.outcome == .errored || result.outcome == .timedOut:
            "\(result.outcome.rawValue): \(result.mutation.id)\n\(result.diagnostic ?? "Test execution couldn't be verified.")"
        case .measured, .finished: nil
        }
    }
}
