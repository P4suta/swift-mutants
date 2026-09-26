// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Installs a `swift` and an `xcodebuild` that answer from a rule table a test wrote.
///
/// The unit tier can therefore test what swift-mutants does when a toolchain misbehaves.
/// A `swift build` that hangs cannot be installed; a `--version` that prints garbage, a
/// `describe` that refuses a pattern, and a baseline that is red would otherwise each be an
/// integration test costing minutes and a real toolchain - or, more often, no test at all.
///
/// It also gives the unit tier an assertion it could not otherwise make. ``calls()`` is the
/// argument vector, the working directory and the variables a child process *really*
/// received, so "the compile carries the instrumented tree's flags and the pristine
/// baseline does not" becomes a claim about a process rather than about a struct.
///
/// A call no rule matches exits 97. A test can never pass on a command nobody scripted.
public struct FakeToolchain: Sendable {

    /// A directory to put on `PATH`, holding a `swift` and an `xcodebuild`.
    public let pathEntry: String

    /// The variables a child needs in order to find the rule table and the call log.
    ///
    /// Merged into whatever environment the thing under test composes, because the fake is
    /// reached as a process and a process only knows what it is given.
    public let environment: [String: String]

    private let root: URL
    private let callLog: URL

    /// Scripts a toolchain.
    ///
    /// The rules are tried in order and the first whose arguments appear, in sequence, in
    /// the call wins. Matching a subsequence rather than the whole vector is what lets a
    /// test script the part it cares about - `["build", "--build-tests"]` - without
    /// restating the scratch path the engine happened to choose.
    public init(_ rules: [FakeToolchainRule], in directory: URL? = nil) throws {
        root =
            directory
            ?? FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let ruleTable = root.appending(path: "rules.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(rules).write(to: ruleTable)

        callLog = root.appending(path: "calls.jsonl")
        FileManager.default.createFile(atPath: callLog.path, contents: Data())

        let binaries = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let executable = try Self.builtExecutable()
        for name in ["swift", "swiftc", "xcodebuild", "xcrun"] {
            try FileManager.default.createSymbolicLink(
                at: binaries.appending(path: name),
                withDestinationURL: executable
            )
        }

        pathEntry = binaries.path
        environment = [
            FakeToolchainEnvironment.ruleTable: ruleTable.path,
            FakeToolchainEnvironment.callLog: callLog.path,
        ]
    }

    /// Every call the scripted toolchain was asked to answer, in order.
    ///
    /// Including the ones no rule matched: what a test most wants to see after an
    /// unscripted-command failure is the command.
    public func calls() throws -> [FakeToolchainCall] {
        let text = try String(contentsOf: callLog, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map {
            try decoder.decode(FakeToolchainCall.self, from: Data($0.utf8))
        }
    }

    /// Removes everything the fake installed.
    public func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Where the built fake sits.
    ///
    /// `Bundle.main` is no help: under swift-testing the running executable is the xctest runner out of the toolchain, so the main bundle points into Xcode rather than at this package's products.
    /// The test executable itself does help: a SwiftPM product is beside its test bundle, even when the caller chose a scratch directory this package has never heard of.
    /// The repository layouts remain as fallbacks, and every candidate is named in the failure so that an unexpected layout says which places were tried.
    private static func builtExecutable() throws -> URL {
        let candidates =
            Self.buildDirectories(around: URL(filePath: CommandLine.arguments[0])).map {
                $0.appending(path: "swift-mutants-fake-toolchain")
            }
        if let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return found
        }
        // What `.build` actually holds, because the layout is the thing that changes and a list of places that were wrong does not say which place is right.
        // CI reported two candidates and no others, which meant this could not read `.build` at all, and nothing in the message said whether it was missing, empty or unreadable.
        let build = RepositoryGate.root.appending(path: ".build")
        let held =
            (try? FileManager.default.contentsOfDirectory(atPath: build.path))
            .map { $0.isEmpty ? "<empty>" : $0.sorted().joined(separator: ", ") }
            ?? "<not readable>"
        throw Failure(
            """
            swift-mutants-fake-toolchain was not found. `swift build --build-tests` builds \
            it; if it is missing, the package layout has changed.
            Looked in:
            \(candidates.map { "  " + $0.path }.joined(separator: "\n"))
            \(build.path) holds: \(held)
            """
        )
    }

    /// Every place a build might have put its products, most likely first.
    ///
    /// The ancestors of the test executable cover the default build directory, an arbitrary `--scratch-path`, debug and release configurations, and both the bundled Darwin runner and the direct executable used elsewhere.
    /// `.build/debug` is the compatibility location SwiftPM maintains, and the directories beneath `.build` cover older triple-specific and newer `out/Products` layouts.
    static func buildDirectories(around executable: URL) -> [URL] {
        let build = RepositoryGate.root.appending(path: ".build")
        var directories: [URL] = []
        for spelling in [executable.standardizedFileURL, executable.resolvingSymlinksInPath()] {
            var directory = spelling.deletingLastPathComponent()
            for _ in 0..<6 {
                directories.append(directory)
                let parent = directory.deletingLastPathComponent()
                guard parent.path != directory.path else { break }
                directory = parent
            }
        }
        // `.build/debug` is a symlink SwiftPM keeps for compatibility.
        // The products themselves sit under `out/Products` in one layout and under a triple-specific directory in another.
        directories += [
            build.appending(path: "debug"),
            build.appending(path: "release"),
            build.appending(path: "out/Products/Debug"),
            build.appending(path: "out/Products/Release"),
        ]
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: build,
                includingPropertiesForKeys: nil
            )) ?? []
        for triple in contents.sorted(by: { $0.path < $1.path }) {
            directories.append(triple.appending(path: "debug"))
            directories.append(triple.appending(path: "release"))
        }
        var seen: Set<String> = []
        return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// A fake toolchain that could not be installed.
    public struct Failure: Error, CustomStringConvertible {
        /// What went wrong, and where.
        public let description: String

        /// Creates a failure from an already-rendered description.
        public init(_ description: String) { self.description = description }
    }
}
