// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import SwiftMutantsTestKit
import Testing

/// The claim the whole design rests on, put to the compiler.
///
/// Everything else about instrumentation is a statement about text. This asks the two
/// questions text cannot answer: does the instrumented file compile, and does one
/// environment variable really change which program runs? A tool that got either wrong
/// would produce a mutation score about a program nobody ran.
@Suite("Instrumented code, compiled and run")
struct InstrumentIntegrationTests {

    static let subject = """
        func classify(_ a: Int, _ b: Int) -> String {
            if a < b {
                return "less"
            }
            return "not-less"
        }

        func both(_ a: Bool, _ b: Bool) -> Bool {
            return a && b
        }

        // A site inside a loop, so that a probe run has something to write down a
        // hundred thousand times if it is going to.
        func counted(_ limit: Int) -> Int {
            var total = 0
            for value in 0..<limit where value % 2 == 0 {
                total += 1
            }
            return total
        }
        """

    static let driver = """
        let arguments = CommandLine.arguments
        print(classify(Int(arguments[1]) ?? 0, Int(arguments[2]) ?? 0))
        print(both(arguments[3] == "y", arguments[4] == "y"))
        print(counted(100_000))
        """

    /// A built subject, and the way to take it away again.
    struct Built {
        let binary: URL
        let mutants: [InstrumentedMutant]
        let cleanUp: () -> Void
    }

    /// Builds the instrumented subject into a binary and returns a way to run it.
    static func build() throws -> Built {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        let discovery = Discover.candidates(in: Self.subject, at: path)
        let instrumented = try Instrument.file(Self.subject, discovery: discovery)

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-instrumented-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanUp: () -> Void = { try? FileManager.default.removeItem(at: directory) }

        try Data(instrumented.source.utf8).write(to: directory.appending(path: "Subject.swift"))
        try Data(Self.driver.utf8).write(to: directory.appending(path: "main.swift"))

        let binary = directory.appending(path: "subject")
        _ = try ToolchainGate.run(
            "swiftc",
            [
                "-swift-version", "6", "-O",
                directory.appending(path: "Subject.swift").path,
                directory.appending(path: "main.swift").path,
                "-o", binary.path,
            ]
        )
        return Built(binary: binary, mutants: instrumented.mutants, cleanUp: cleanUp)
    }

    static func run(_ binary: URL, activating mutant: UInt32?) throws -> [String] {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["2", "2", "y", "n"]
        if let mutant {
            var environment = ProcessInfo.processInfo.environment
            environment["SWIFT_MUTANTS_ACTIVE"] = "\(mutant)"
            process.environment = environment
        }
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let produced = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: produced, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    /// What the guards write down when they are asked to.
    ///
    /// This is the whole economy of a fast run. Without it a mutant costs the time the
    /// suite takes, because every test has to be run in case one of them notices; with it
    /// a mutant costs only the tests that reach it, and a mutant nothing reaches costs no
    /// process at all.
    ///
    /// A guard is the right place to record from: it is evaluated exactly when its site
    /// is, it adds no expression for the compiler to type-check, and nothing can reach it
    /// without the mutant having been reachable.
    @Test("writes down which mutants a run reached", .tags(.integration))
    func probesRecordWhatWasReached() throws {
        let built = try Self.build()
        defer { built.cleanUp() }

        let log = built.binary.deletingLastPathComponent().appending(path: "probe.log")
        // `classify(2, 2)` takes the `a < b` site; `both` is never called, so the mutants
        // in it are never reached.
        let reached = try Self.probe(built.binary, writingTo: log, arguments: ["2", "2", "y", "n"])

        let comparisons = built.mutants.filter { $0.rule.name == "lt-to-le" }.map(\.index)
        #expect(!comparisons.isEmpty)
        #expect(Set(comparisons).isSubset(of: reached), "\(reached)")
    }

    /// A site inside a loop is written down once, not once per turn. Otherwise a probe run
    /// of a program that does any real work writes a log nobody can read.
    @Test("writes each mutant down once however often it is reached", .tags(.integration))
    func probesRecordOnce() throws {
        let built = try Self.build()
        defer { built.cleanUp() }

        let log = built.binary.deletingLastPathComponent().appending(path: "once.log")
        _ = try Self.probe(built.binary, writingTo: log, arguments: ["2", "2", "y", "n"])

        let lines = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(!lines.isEmpty)
        #expect(Set(lines).count == lines.count, "a mutant was written down twice: \(lines)")
    }

    /// And when nobody asks, nothing is written and nothing is opened.
    @Test("writes nothing when no probe was asked for", .tags(.integration))
    func probesAreOffByDefault() throws {
        let built = try Self.build()
        defer { built.cleanUp() }
        let log = built.binary.deletingLastPathComponent().appending(path: "absent.log")

        _ = try Self.run(built.binary, activating: nil)
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    /// Runs the subject with probing on and returns the indices it wrote down.
    static func probe(_ binary: URL, writingTo log: URL, arguments: [String]) throws -> Set<UInt32>
    {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SWIFT_MUTANTS_PROBE"] = log.path
        process.environment = environment
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { UInt32($0) })
    }

    /// The instrumented file has to be a program the compiler accepts. Everything else is
    /// theory until it is.
    @Test("compiles", .tags(.integration))
    func compiles() throws {
        let built = try Self.build()
        defer { built.cleanUp() }
        #expect(FileManager.default.isExecutableFile(atPath: built.binary.path))
    }

    /// With nothing activated the instrumented program has to behave exactly as the
    /// original did, or the baseline this tool measures everything against is a measurement
    /// of something else.
    @Test("behaves as the original when no mutant is awake", .tags(.integration))
    func behavesAsTheOriginal() throws {
        let built = try Self.build()
        defer { built.cleanUp() }
        // 2 < 2 is false, and (true && false) is false.
        #expect(try Self.run(built.binary, activating: nil) == ["not-less", "false", "50000"])
    }

    /// The claim itself: one environment variable, one different program.
    @Test("changes exactly one thing when a mutant is woken", .tags(.integration))
    func oneVariableChangesOneThing() throws {
        let built = try Self.build()
        defer { built.cleanUp() }
        let comparison = try #require(built.mutants.first { $0.rule.name == "lt-to-le" })
        let connective = try #require(built.mutants.first { $0.rule.name == "and-to-or" })

        // `<` becomes `<=`, so 2 <= 2 is now true. The connective is untouched.
        #expect(
            try Self.run(built.binary, activating: comparison.index) == ["less", "false", "50000"])
        // `&&` becomes `||`, so (true || false) is now true. The comparison is untouched.
        #expect(
            try Self.run(built.binary, activating: connective.index) == [
                "not-less", "true", "50000",
            ])
    }

    /// A guard is an integer compare against a global the runtime read once, and `-O` must
    /// not be able to fold it away - the whole file would otherwise compile down to the
    /// original program and every mutant would survive.
    @Test("survives optimisation", .tags(.integration))
    func survivesOptimisation() throws {
        let built = try Self.build()
        defer { built.cleanUp() }
        let comparison = try #require(built.mutants.first { $0.rule.name == "lt-to-le" })
        #expect(
            try Self.run(built.binary, activating: comparison.index)
                != Self.run(built.binary, activating: nil))
    }

    /// An index no mutant has must leave the program as it was, rather than waking whatever
    /// happens to be nearby.
    @Test("ignores an index that names no mutant", .tags(.integration))
    func unknownIndexWakesNothing() throws {
        let built = try Self.build()
        defer { built.cleanUp() }
        #expect(try Self.run(built.binary, activating: 9999) == ["not-less", "false", "50000"])
    }
}

extension Tag {
    /// Needs a real Swift toolchain.
    @Tag static var integration: Self
}
