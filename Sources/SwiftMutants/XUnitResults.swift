// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct XUnitResults: Sendable, Equatable {
    var executed: [String: Int] = [:]
    var skipped: [String: Int] = [:]
    var failures = 0
    var errors = 0

    static func parse(_ data: Data, framework: String) throws -> Self {
        guard let text = String(data: data, encoding: .utf8),
            !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY")
        else { throw XUnitError.invalidDocument }
        let reader = XUnitReader(framework: framework)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let parsed = withExtendedLifetime(reader) {
            unsafe parser.delegate = reader
            let parsed = parser.parse()
            unsafe parser.delegate = nil
            return parsed
        }
        guard parsed, !reader.invalid, reader.sawRoot else {
            throw XUnitError.invalidDocument
        }
        return reader.results
    }

    mutating func merge(_ other: Self) {
        executed.merge(other.executed, uniquingKeysWith: +)
        skipped.merge(other.skipped, uniquingKeysWith: +)
        failures += other.failures
        errors += other.errors
    }
}

enum XUnitError: Error {
    case invalidDocument
}

private final class XUnitReader: NSObject, XMLParserDelegate {
    let framework: String
    var results = XUnitResults()
    var invalid = false
    var sawRoot = false
    var depth = 0
    var suites: [SuiteCount] = []
    var current: TestCase?

    struct SuiteCount {
        var expected: [String: Int]
        var actual: [String: Int] = [:]
        var failedTests = 0
        var erroredTests = 0
    }

    struct TestCase {
        let identity: String
        var skipped = false
        var failed = false
        var errored = false
    }

    init(framework: String) { self.framework = framework }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        if depth == 0 {
            sawRoot = elementName == "testsuites" || elementName == "testsuite"
            if !sawRoot { invalid = true }
        }
        depth += 1
        switch elementName {
        case "testsuite", "testsuites": beginSuite(attributes)
        case "testcase": beginCase(attributes)
        case "failure", "error", "skipped": record(elementName)
        default: break
        }
    }

    private func beginSuite(_ attributes: [String: String]) {
        if current != nil { invalid = true }
        var expected: [String: Int] = [:]
        for key in ["tests", "failures", "errors", "skipped"] {
            guard let text = attributes[key] else { continue }
            guard let count = Int(text), count >= 0 else { invalid = true; continue }
            expected[key] = count
        }
        suites.append(SuiteCount(expected: expected))
    }

    private func beginCase(_ attributes: [String: String]) {
        guard current == nil, !suites.isEmpty, let name = attributes["name"], !name.isEmpty else {
            invalid = true
            return
        }
        current = TestCase(identity: "\(framework):\(attributes["classname", default: ""])/\(name)")
        increment("tests")
    }

    private func increment(_ key: String) {
        for index in suites.indices { suites[index].actual[key, default: 0] += 1 }
    }

    private func record(_ element: String) {
        guard current != nil else { invalid = true; return }
        switch element {
        case "failure":
            current?.failed = true
            increment("failures")
        case "error":
            current?.errored = true
            increment("errors")
        case "skipped":
            current?.skipped = true
            increment("skipped")
        default: break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        depth -= 1
        switch elementName {
        case "testcase": finishCase()
        case "testsuite", "testsuites": finishSuite()
        default: break
        }
    }

    private func finishCase() {
        guard let test = current else { invalid = true; return }
        if test.skipped {
            if test.failed || test.errored { invalid = true }
            results.skipped[test.identity, default: 0] += 1
        } else {
            results.executed[test.identity, default: 0] += 1
            if test.failed { results.failures += 1 }
            if test.errored { results.errors += 1 }
        }
        for index in suites.indices {
            if test.failed { suites[index].failedTests += 1 }
            if test.errored { suites[index].erroredTests += 1 }
        }
        current = nil
    }

    private func finishSuite() {
        guard let suite = suites.popLast() else { invalid = true; return }
        for (key, expected) in suite.expected {
            let actual = suite.actual[key, default: 0]
            if key == "failures", expected == suite.failedTests { continue }
            if key == "errors", expected == suite.erroredTests { continue }
            if expected != actual { invalid = true }
        }
    }
}
