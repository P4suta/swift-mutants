// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct TestIdentity: Sendable, Hashable {
    let framework: String
    let className: String
    let name: String
}

struct XUnitResults: Sendable, Equatable {
    var executed: [TestIdentity: Int] = [:]
    var skipped: [TestIdentity: Int] = [:]
    var failures = 0
    var errors = 0

    var hasXCTest: Bool {
        executed.keys.contains { $0.framework.hasSuffix(":xctest") }
            || skipped.keys.contains { $0.framework.hasSuffix(":xctest") }
    }

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
        guard parsed, !reader.invalid, reader.sawRoot,
            reader.elements.isEmpty, reader.suites.isEmpty, reader.current == nil
        else {
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
    var elements: [XUnitElement] = []
    var suites: [SuiteCount] = []
    var current: TestCase?

    struct SuiteCount {
        var expected: [String: Int]
        var actual: [String: Int] = [:]
        var failedTests = 0
        var erroredTests = 0
        var skippedTests = 0
    }

    struct TestCase {
        let identity: TestIdentity
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
        guard !invalid else { return }
        guard let element = XUnitElement(rawValue: elementName) else {
            invalid = true
            return
        }
        if let parent = elements.last {
            guard parent.permits(element) else { invalid = true; return }
        } else {
            sawRoot = element == .suites || element == .suite
            guard sawRoot else { invalid = true; return }
        }
        elements.append(element)
        switch element {
        case .suite, .suites: beginSuite(attributes)
        case .testCase: beginCase(attributes)
        case .failure, .error, .skipped: record(element)
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
        current = TestCase(
            identity: TestIdentity(
                framework: framework,
                className: attributes["classname", default: ""],
                name: name
            )
        )
        increment("tests")
    }

    private func increment(_ key: String) {
        for index in suites.indices { suites[index].actual[key, default: 0] += 1 }
    }

    private func record(_ element: XUnitElement) {
        guard current != nil else { invalid = true; return }
        switch element {
        case .failure:
            current?.failed = true
            increment("failures")
        case .error:
            current?.errored = true
            increment("errors")
        case .skipped:
            guard current?.skipped == false else { invalid = true; return }
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
        guard !invalid else { return }
        guard let element = elements.popLast() else { invalid = true; return }
        switch element {
        case .testCase: finishCase()
        case .suite, .suites: finishSuite()
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
            if test.skipped { suites[index].skippedTests += 1 }
        }
        current = nil
    }

    private func finishSuite() {
        guard let suite = suites.popLast() else { invalid = true; return }
        for (key, expected) in suite.expected {
            let actual = suite.actual[key, default: 0]
            if key == "tests", expected == actual - suite.skippedTests { continue }
            if key == "failures", expected == suite.failedTests { continue }
            if key == "errors", expected == suite.erroredTests { continue }
            if expected != actual { invalid = true }
        }
    }
}

private enum XUnitElement: String {
    case suites = "testsuites"
    case suite = "testsuite"
    case testCase = "testcase"
    case failure, error, skipped, properties, property
    case standardOutput = "system-out"
    case standardError = "system-err"

    func permits(_ child: Self) -> Bool {
        switch child {
        case .suites: false
        case .suite: self == .suites || self == .suite
        case .testCase: self == .suite
        case .failure, .error, .skipped: self == .testCase
        case .properties, .standardOutput, .standardError:
            self == .suites || self == .suite || self == .testCase
        case .property: self == .properties
        }
    }
}
