// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutants

@Suite("XML result properties")
struct XUnitPropertyTests {
    @Test("nested suite counts preserve every case and outcome")
    func generatedSuites() throws {
        for seed in 0..<256 {
            let cases = (0..<4).map { index in
                Case(
                    identity: TestIdentity(
                        framework: "property",
                        className: "Suite/\(index % 2)",
                        name: "case\(seed.isMultiple(of: 3) ? 0 : index) & \"<\u{00E9}\u{1F600}>"
                    ),
                    status: (seed >> (index * 2)) & 3,
                    issues: index % 2 + 1
                )
            }
            for startedCount in [false, true] {
                for issueCount in [false, true] {
                    let document = Self.document(
                        cases, startedCount: startedCount, issueCount: issueCount
                    )
                    let parsed = try XUnitResults.parse(Data(document.utf8), framework: "property")
                    var expected = XUnitResults()
                    for item in cases {
                        if item.status == 3 {
                            expected.skipped[item.identity, default: 0] += 1
                        } else {
                            expected.executed[item.identity, default: 0] += 1
                        }
                        if item.status == 1 { expected.failures += 1 }
                        if item.status == 2 { expected.errors += 1 }
                    }
                    #expect(
                        parsed == expected,
                        "seed=\(seed), started=\(startedCount), issues=\(issueCount)")
                }
            }
        }
    }

    private struct Case {
        let identity: TestIdentity
        let status: Int
        let issues: Int

        var xml: String {
            let content: String
            switch status {
            case 1: content = String(repeating: "<failure message=\"assertion\"/>", count: issues)
            case 2: content = String(repeating: "<error message=\"runner\"/>", count: issues)
            case 3: content = "<skipped/>"
            default: content = ""
            }
            let className = Self.escape(identity.className)
            let name = Self.escape(identity.name)
            return "<testcase classname=\"\(className)\" name=\"\(name)\">\(content)</testcase>"
        }

        private static func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
    }

    private static func document(
        _ cases: [Case],
        startedCount: Bool,
        issueCount: Bool
    ) -> String {
        let left = Array(cases.prefix(2))
        let right = Array(cases.suffix(2))
        let metadata = """
            <properties><property name="fixture" value="counts"/></properties>
            <system-out><![CDATA[<testcase name="not-a-test"><failure/></testcase>]]></system-out>
            """
        func suite(_ items: [Case]) -> String {
            let counts = Self.attributes(items, startedCount: startedCount, issueCount: issueCount)
            return "<testsuite \(counts)>\(items.map(\.xml).joined())</testsuite>"
        }
        let counts = Self.attributes(cases, startedCount: startedCount, issueCount: issueCount)
        let content = metadata + suite(left) + suite(right)
        return "<testsuites \(counts)><testsuite \(counts)>\(content)</testsuite></testsuites>"
    }

    private static func attributes(
        _ cases: [Case],
        startedCount: Bool,
        issueCount: Bool
    ) -> String {
        let skipped = cases.filter { $0.status == 3 }.count
        let tests = cases.count - (startedCount ? skipped : 0)
        let failures = cases.filter { $0.status == 1 }.reduce(0) {
            $0 + (issueCount ? $1.issues : 1)
        }
        let errors = cases.filter { $0.status == 2 }.reduce(0) {
            $0 + (issueCount ? $1.issues : 1)
        }
        return [
            "tests=\"\(tests)\"", "failures=\"\(failures)\"", "errors=\"\(errors)\"",
            "skipped=\"\(skipped)\"",
        ].joined(separator: " ")
    }
}
