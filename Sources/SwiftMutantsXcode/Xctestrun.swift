// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// The document that says what `xcodebuild test-without-building` will run.
///
/// It is where a mutant is woken on the Xcode path. `test-without-building` has no argument
/// for handing a test an environment variable, so the variable goes into the document
/// instead - and then into every test target, because a scheme with three of them runs
/// three processes and a variable set on one would wake the mutant in a third of the run.
/// That is not a smaller answer; it reads as a mutant two thirds of the suite cannot catch.
///
/// Read and written as a property list, never by editing text. A `.xctestrun` holds paths
/// with spaces in them, arrays, nested dictionaries and a format version, and a tool that
/// rewrote it with string replacement would work until the first project that had any of
/// those - which is every real project.
public struct Xctestrun: Sendable {

    /// A document this tool will not touch.
    public struct Unreadable: Error, Hashable, CustomStringConvertible {

        /// What is wrong with it, in the words a fix needs.
        public let description: String
    }

    /// The format versions this knows how to wake a mutant in.
    ///
    /// A version it does not know is refused rather than guessed at. Waking a mutant in a
    /// document it misread would be a run whose every answer is about a program with
    /// nothing awake - which reads as a suite that catches nothing, silently, for an hour.
    static let knownVersions: Set<Int> = [2]

    /// The document, as a property list.
    private let document: [String: any Sendable]

    /// Where xcodebuild wrote the document this came from.
    ///
    /// Kept because a copy has to live beside it. Every path inside a `.xctestrun` is
    /// written relative to `__TESTROOT__`, which Xcode resolves against the directory the
    /// document is in - so a copy written anywhere else names a bundle that is not there,
    /// and `test-without-building` runs no tests and exits zero. A run built on that would
    /// report every mutant surviving, silently, for an hour. Found exactly that way.
    private let origin: URL

    /// Which format version xcodebuild wrote.
    public let formatVersion: Int

    /// What each test target in it is called, in the order the document holds them.
    public var testTargetNames: [String] {
        Self.targets(of: document).compactMap { $0["BlueprintName"] as? String }
    }

    /// Reads one xcodebuild wrote, or refuses it.
    public init(contentsOf file: URL) throws(Unreadable) {
        guard let data = try? Data(contentsOf: file) else {
            throw Unreadable(description: "no .xctestrun at \(file.path)")
        }
        // `format:` takes a pointer this does not need, which is what makes the call
        // unsafe under strict memory safety. Passing nothing is the documented way to say
        // "read whichever format it is", and nothing is dereferenced on this side of it.
        guard
            let parsed = unsafe try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
            let document = parsed as? [String: any Sendable]
        else {
            throw Unreadable(
                description: "\(file.lastPathComponent) is not a property list xcodebuild wrote")
        }
        try self.init(document, from: file)
    }

    /// The same, for a document already in hand.
    init(_ document: [String: any Sendable], from origin: URL) throws(Unreadable) {
        let metadata = document["__xctestrun_metadata__"] as? [String: any Sendable]
        guard let version = metadata?["FormatVersion"] as? Int else {
            throw Unreadable(description: "this .xctestrun does not say which format it is")
        }
        guard Self.knownVersions.contains(version) else {
            throw Unreadable(
                description: """
                    this .xctestrun is format version \(version), and swift-mutants knows \
                    \(Self.knownVersions.sorted().map(String.init).joined(separator: ", ")). \
                    Waking a mutant in a document it had misread would be an hour of \
                    answers about a program with nothing awake.
                    """
            )
        }
        guard !Self.targets(of: document).isEmpty else {
            throw Unreadable(
                description: "this .xctestrun has no test targets in it, so there is nothing to run"
            )
        }
        self.document = document
        self.formatVersion = version
        self.origin = origin
    }

    /// The environment one test target will be given, if the document has that target.
    public func environment(ofTarget name: String) -> [String: String]? {
        Self.targets(of: document)
            .first { $0["BlueprintName"] as? String == name }
            .map { ($0["EnvironmentVariables"] as? [String: String]) ?? [:] }
    }

    /// The same document with these variables added to every test target.
    ///
    /// Added rather than replacing: xcodebuild puts variables of its own in there -
    /// `DYLD_INSERT_LIBRARIES`, `TERM` - and a document that dropped them would run the
    /// tests in an environment Xcode did not intend, which is a different program from the
    /// one the baseline measured.
    public func waking(_ variables: [String: String]) -> Self {
        var copy = document
        var configurations = (copy["TestConfigurations"] as? [[String: any Sendable]]) ?? []
        for index in configurations.indices {
            var targets = (configurations[index]["TestTargets"] as? [[String: any Sendable]]) ?? []
            for target in targets.indices {
                var environment =
                    (targets[target]["EnvironmentVariables"] as? [String: String]) ?? [:]
                environment.merge(variables) { _, waking in waking }
                targets[target]["EnvironmentVariables"] = environment
            }
            configurations[index]["TestTargets"] = targets
        }
        copy["TestConfigurations"] = configurations
        // The document came from a readable one and gained only strings, so it is still
        // readable. Nothing here can make it otherwise, and a throwing accessor for a case
        // that cannot arise would be a second thing for a caller to get wrong.
        guard let rebuilt = try? Self(copy, from: origin) else { return self }
        return rebuilt
    }

    /// Writes this document beside the one it came from, under `name`, and says where.
    ///
    /// Beside, and nowhere else. Every path inside a `.xctestrun` is written relative to
    /// `__TESTROOT__`, which Xcode resolves against the directory the document is in - so a
    /// copy written to a scratch directory names a bundle that is not there, and
    /// `test-without-building` then runs no tests **and exits zero**. A run built on that
    /// reports every mutant surviving, silently, for an hour. There is no parameter for the
    /// directory because there is no right answer other than this one.
    ///
    /// A copy, never over the original: one build serves every mutant, and a document
    /// edited in place would leave the last mutant's variable set for whatever ran next -
    /// including the baseline.
    @discardableResult
    public func write(named name: String) throws -> URL {
        let directory = origin.deletingLastPathComponent()
        let file = directory.appending(path: "\(name).xctestrun")
        let data = try PropertyListSerialization.data(
            fromPropertyList: document, format: .xml, options: 0)
        try data.write(to: file)
        return file
    }

    /// Every test target of every configuration, in document order.
    private static func targets(of document: [String: any Sendable]) -> [[String: any Sendable]] {
        ((document["TestConfigurations"] as? [[String: any Sendable]]) ?? [])
            .flatMap { ($0["TestTargets"] as? [[String: any Sendable]]) ?? [] }
    }
}
