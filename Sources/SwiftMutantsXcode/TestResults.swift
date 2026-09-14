// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// What a result bundle says about each test.
///
/// This is where a mutant is decided on the Xcode path, and the way it goes wrong is
/// silent. A reader that took a bundle-level `Failed` for a test would call every mutant
/// killed; one that took an unknown verdict for a pass would call every mutant a survivor.
/// Both are a score somebody believes.
///
/// So it fails closed at every step. A node it does not understand is a node it says
/// nothing about; a document it cannot read establishes nothing rather than nothing having
/// failed; and a test it cannot name is left out rather than reported as a killer somebody
/// cannot go and find.
public struct TestResults: Sendable, Hashable {

    /// A document this tool will not read.
    public struct Unreadable: Error, Hashable, CustomStringConvertible {

        /// What is wrong with it, in the words a fix needs.
        public let description: String
    }

    /// Every test the run started, named the way Xcode names it.
    public let started: [String]

    /// The ones that failed, in the order the document holds them.
    public let failed: [String]

    /// Whether anything failed, which is what decides a mutant.
    public var anythingFailed: Bool { !failed.isEmpty }

    /// Reads what `xcresulttool get test-results tests --compact` wrote.
    public init(_ document: Data) throws(Unreadable) {
        guard let parsed = try? JSONSerialization.jsonObject(with: document),
            let root = parsed as? [String: Any],
            let nodes = root["testNodes"] as? [[String: Any]]
        else {
            throw Unreadable(
                description: """
                    this is not a document `xcresulttool get test-results tests` wrote, so \
                    nothing is known about what ran - which is not the same as nothing \
                    having failed
                    """
            )
        }
        var started: [String] = []
        var failed: [String] = []
        Self.walk(nodes, into: &started, and: &failed)
        self.started = started
        self.failed = failed
    }

    /// Every test case under these nodes, however deeply Xcode nested them.
    private static func walk(
        _ nodes: [[String: Any]], into started: inout [String], and failed: inout [String]
    ) {
        for node in nodes {
            if let children = node["children"] as? [[String: Any]] {
                walk(children, into: &started, and: &failed)
            }
            // A bundle and a plan carry a verdict of their own and neither is a test. One
            // counted as a test would be reported as a killer somebody could go and look
            // at, and there would be nothing there.
            guard node["nodeType"] as? String == "Test Case",
                let name = Self.name(of: node),
                let verdict = node["result"] as? String
            else { continue }
            switch verdict {
            case "Passed":
                started.append(name)
            case "Failed":
                started.append(name)
                failed.append(name)
            default:
                // Skipped, an expected failure, or whatever Xcode adds next: nothing was
                // established here, and reading one as a pass is how a mutant nothing ran
                // against comes back a survivor.
                break
            }
        }
    }

    /// What a report will call this test.
    ///
    /// From the URL Xcode gives rather than rebuilt from the names, because the names
    /// repeat between bundles and the URL does not - and a report that showed two different
    /// tests under one name would send somebody to the wrong file.
    private static func name(of node: [String: Any]) -> String? {
        guard let url = node["nodeIdentifierURL"] as? String else { return nil }
        let prefix = "test://com.apple.xcode/"
        guard url.hasPrefix(prefix) else { return nil }
        let path = String(url.dropFirst(prefix.count))
        return path.isEmpty ? nil : path
    }
}
