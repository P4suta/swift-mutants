// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

enum XCTestTranscript {
    enum Completion {
        case passed, failed, skipped
    }

    static func reconcile(_ results: inout XUnitResults, output: String, framework: String) throws {
        var completions: [TestIdentity: [Completion]] = [:]
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("Test Case '-["),
                let start = line.range(of: "Test Case '-["),
                let end = line[start.upperBound...].range(of: "]' ")
            else { continue }
            let title = line[start.upperBound..<end.lowerBound]
            guard let separator = title.lastIndex(of: " ") else { continue }
            let identity = TestIdentity(
                framework: framework,
                className: String(title[..<separator]),
                name: String(title[title.index(after: separator)...])
            )
            let status = line[end.upperBound...]
            let completion: Completion
            if status.hasPrefix("passed (") {
                completion = .passed
            } else if status.hasPrefix("failed (") {
                completion = .failed
            } else if status.hasPrefix("skipped (") {
                completion = .skipped
            } else {
                continue
            }
            completions[identity, default: []].append(completion)
        }
        guard Set(completions.keys) == Set(results.executed.keys),
            completions.values.flatMap({ $0 }).filter({ $0 == .failed }).count == results.failures
        else { throw XUnitError.invalidDocument }
        for (identity, count) in results.executed {
            guard let finished = completions[identity], finished.count == count else {
                throw XUnitError.invalidDocument
            }
            let skipped = finished.filter { $0 == .skipped }.count
            if skipped > 0 {
                results.skipped[identity, default: 0] += skipped
                results.executed[identity] = count == skipped ? nil : count - skipped
            }
        }
    }
}
