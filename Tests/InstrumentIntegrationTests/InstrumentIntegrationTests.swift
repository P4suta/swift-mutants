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
        """

    static let driver = """
        let arguments = CommandLine.arguments
        print(classify(Int(arguments[1]) ?? 0, Int(arguments[2]) ?? 0))
        print(both(arguments[3] == "y", arguments[4] == "y"))
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
        #expect(try Self.run(built.binary, activating: nil) == ["not-less", "false"])
    }

    /// The claim itself: one environment variable, one different program.
    @Test("changes exactly one thing when a mutant is woken", .tags(.integration))
    func oneVariableChangesOneThing() throws {
        let built = try Self.build()
        defer { built.cleanUp() }
        let comparison = try #require(built.mutants.first { $0.rule.name == "lt-to-le" })
        let connective = try #require(built.mutants.first { $0.rule.name == "and-to-or" })

        // `<` becomes `<=`, so 2 <= 2 is now true. The connective is untouched.
        #expect(try Self.run(built.binary, activating: comparison.index) == ["less", "false"])
        // `&&` becomes `||`, so (true || false) is now true. The comparison is untouched.
        #expect(try Self.run(built.binary, activating: connective.index) == ["not-less", "true"])
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
        #expect(try Self.run(built.binary, activating: 9999) == ["not-less", "false"])
    }
}

extension Tag {
    /// Needs a real Swift toolchain.
    @Tag static var integration: Self
}
