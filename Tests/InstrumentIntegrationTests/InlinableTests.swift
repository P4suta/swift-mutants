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
