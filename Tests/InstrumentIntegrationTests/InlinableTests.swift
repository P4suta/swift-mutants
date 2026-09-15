// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import Testing

@testable import SwiftMutantsInstrument

/// Instrumenting code a package has marked `@inlinable`.
///
/// Swift will not let an `@inlinable` function reference a `private` symbol, so a guard
/// that is private makes every mutant inside such a function unbuildable. They then arrive
/// at validation as refusals with no cause a reader can see, and the score quietly excludes
/// whatever the package decided was hot.
///
/// Reported from a real package: seventeen `@inlinable` functions across three files, all
/// of them the inner loops of a layout solver - which is to say exactly the code somebody
/// cares most about being right.
///
/// The guard is therefore `@usableFromInline internal` rather than `private`. Visible to
/// the module rather than to the file, which costs nothing: the name carries a digest of
/// the file's path and contents, so two instrumented files cannot collide.
@Suite("Instrumenting code marked inlinable", .tags(.integration))
struct InlinableTests {

    /// A package's hot path, marked the way a package marks one.
    static let inlinable = """
        @inlinable public func hot(_ a: Int, _ b: Int) -> Bool {
            a < b
        }

        @inlinable public func alsoHot(_ a: Bool, _ b: Bool) -> Bool {
            a && b
        }

        public func ordinary(_ a: Int, _ b: Int) -> Int {
            a + b
        }
        """

    static func instrument(_ source: String, named name: String) throws -> InstrumentedFile {
        guard let path = WorkspaceRelativePath("Sources/\(name).swift") else {
            fatalError("malformed fixture path")
        }
        return try Instrument.file(source, discovery: Discover.candidates(in: source, at: path))
    }

    /// Compiles a file the way a package would, and says what the compiler said.
    static func compile(
        _ sources: [String: String], extra: [String] = []
    ) throws -> (
        exitCode: Int32, text: String
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-inlinable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var paths: [String] = []
        for (name, source) in sources.sorted(by: { $0.key < $1.key }) {
            let file = directory.appending(path: "\(name).swift")
            try Data(source.utf8).write(to: file)
            paths.append(file.path)
        }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/swiftc")
        process.arguments = ["-typecheck", "-swift-version", "6"] + extra + paths
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let said = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: said, as: UTF8.self))
    }

    /// The bug, as reported. Every mutant inside an `@inlinable` function was unbuildable.
    @Test("compiles mutants inside an inlinable function")
    func inlinableCompiles() throws {
        let file = try Self.instrument(Self.inlinable, named: "Hot")
        #expect(file.mutants.count >= 3)

        let result = try Self.compile(["Hot": file.source])
        #expect(result.exitCode == 0, "\(result.text)")
        #expect(!result.text.contains("@inlinable"))
    }

    /// Under the flags a package that cares about this would be using, since `@inlinable`
    /// and library evolution travel together.
    @Test("compiles under library evolution")
    func underLibraryEvolution() throws {
        let file = try Self.instrument(Self.inlinable, named: "Hot")
        let result = try Self.compile(
            ["Hot": file.source],
            extra: ["-enable-library-evolution", "-module-name", "Hot"]
        )
        #expect(result.exitCode == 0, "\(result.text)")
    }

    /// Module-wide visibility is the cost of the fix, so two instrumented files in one
    /// module have to keep out of each other's way. The name carries a digest of the
    /// file's path and its contents, which is what makes that true.
    @Test("keeps two instrumented files in one module apart")
    func twoFilesOneModule() throws {
        let first = try Self.instrument(Self.inlinable, named: "First")
        let second = try Self.instrument(
            """
            @inlinable public func alsoHere(_ a: Int, _ b: Int) -> Bool {
                a > b
            }
            """, named: "Second")

        let result = try Self.compile(["First": first.source, "Second": second.source])
        #expect(result.exitCode == 0, "\(result.text)")
    }

    /// And a package with nothing inlinable in it is unaffected, which is most packages.
    @Test("compiles a package with nothing inlinable in it")
    func ordinaryStillCompiles() throws {
        let file = try Self.instrument(
            """
            func f(_ a: Int, _ b: Int) -> Bool { a < b }
            """, named: "Plain")
        let result = try Self.compile(["Plain": file.source])
        #expect(result.exitCode == 0, "\(result.text)")
    }
}

/// A dropped condition clause, compiled.
///
/// The discovery tests fix which clauses are offered; this fixes that the offered ones are
/// Swift. A condition list sits inside a statement rather than inside an expression, so it
/// is instrumented differently from an operator - and a family that generated mutants the
/// compiler refuses would cost a compile per mutant to learn nothing.
@Suite("A dropped condition clause compiles", .tags(.integration))
struct DroppedConditionTests {

    static let subject = """
        public func scale(_ text: String) -> Double? {
            guard let value = Double(text), value > 0, value.isFinite else { return nil }
            return value
        }

        public func both(_ a: Bool, _ b: Bool) -> Int {
            if a, b { return 1 }
            return 0
        }

        public func counting(_ limit: Int, _ on: Bool) -> Int {
            var total = 0
            var index = 0
            while index < limit, on {
                total += 1
                index += 1
            }
            return total
        }
        """

    @Test("compiles with every clause it offers to drop")
    func compiles() throws {
        let file = try InlinableTests.instrument(Self.subject, named: "Conditions")
        let dropped = file.mutants.filter { $0.rule.name == "drop-condition" }
        #expect(dropped.count >= 5)

        let result = try InlinableTests.compile(["Conditions": file.source])
        #expect(result.exitCode == 0, "\(result.text)")
    }

    /// And the guard's binding is still there in every one of them, which is what stops
    /// the body from naming something that is gone.
    @Test("keeps a binding every clause after it depends on")
    func keepsTheBinding() throws {
        let file = try InlinableTests.instrument(Self.subject, named: "Conditions")
        let dropped = file.mutants.filter { $0.rule.name == "drop-condition" }
        // Never the binding itself, which is not an expression and which everything
        // after it names.
        #expect(!dropped.contains { $0.original.contains("Double(text)") })
        #expect(dropped.allSatisfy { $0.replacement == "true" })
    }
}

/// A conditional made into a no-op, compiled.
///
/// The same reason the dropped clauses have one: the discovery tests were all green
/// against a first version of clause dropping that was not Swift, and only compiling what
/// discovery offers found it.
@Suite("A no-op conditional compiles", .tags(.integration))
struct NoOpConditionTests {

    static let subject = """
        public func clamp(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            if value < 0 { return 0 }
            return value
        }

        public func pick(_ a: Int?, _ b: Bool) -> Int {
            guard let a else { return -1 }
            if b { return a }
            return 0
        }

        public func waiting(_ ready: Bool, _ limit: Int) -> Int {
            var spins = 0
            while !ready, spins < limit { spins += 1 }
            var single = 0
            while single < limit { single += 1 }
            return spins + single
        }
        """

    @Test("compiles every conditional it makes a no-op of")
    func compiles() throws {
        let file = try InlinableTests.instrument(Self.subject, named: "NoOps")
        let noOps = file.mutants.filter { $0.rule.name == "condition-never-decides" }
        // Four: the guard, the `if value < 0`, the `if b`, and the single-clause `while`.
        // Not the `guard let a`, and not the two-clause `while`, which is the other
        // family's question.
        #expect(noOps.count == 4)
        #expect(!noOps.contains { $0.original.contains("let a") })

        let result = try InlinableTests.compile(["NoOps": file.source])
        #expect(result.exitCode == 0, "\(result.text)")
    }

    /// Each keyword gets the constant that makes it do nothing, which is the whole design.
    @Test("gives a guard true and an if false")
    func theRightConstants() throws {
        let file = try InlinableTests.instrument(Self.subject, named: "NoOps")
        let noOps = file.mutants.filter { $0.rule.name == "condition-never-decides" }
        #expect(noOps.filter { $0.replacement == "true" }.count == 1)
        #expect(noOps.filter { $0.replacement == "false" }.count == 3)
    }
}
