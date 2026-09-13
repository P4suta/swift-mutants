// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTestKit
import Testing

/// Keeps the pure modules pure.
///
/// A module that cannot open a file, start a process, or read a clock is a module whose
/// golden identity vectors and property tests mean something: run it twice with the same
/// inputs and it must produce the same answer, on any machine, in any order. Every
/// impurity in the engine is therefore pushed out to a named boundary - `Runner` for
/// processes, `Snapshot` for the filesystem, an injected clock for time - and this gate
/// is what keeps it there.
@Suite("Purity gate")
struct PurityGateTests {

    /// Modules that may import nothing outside ``permittedImports``.
    ///
    /// The strictest tier, and the one the golden identity vectors rest on: a module that
    /// cannot reach a library cannot reach the world through one either.
    static let selfContainedModules = ["SwiftMutantsCore"]

    /// Imports a self-contained module may declare.
    ///
    /// Everything else has to earn a place here, in a commit whose message says why.
    static let permittedImports: Set<String> = ["Synchronization"]

    /// Modules that may import a library but must still reach no file, process or clock.
    ///
    /// `SwiftMutantsTrace` is here rather than in the strict tier because writing a JSON
    /// line needs Foundation's encoder. That is a deliberate trade: a hand-written encoder
    /// would own the byte-exact output, but a golden test pins those bytes for a fraction
    /// of the code and fails just as loudly if Foundation ever changes its mind.
    static let effectFreeModules = ["SwiftMutantsCore", "SwiftMutantsTrace"]

    /// Names that mean "this code reached for the world".
    ///
    /// Time is on the list alongside the filesystem and processes because a clock is the
    /// impurity people forget: a duration computed from `Date()` makes a report that
    /// differs between two runs of the same inputs, which is exactly what a golden test
    /// exists to catch and exactly what it would then be unable to catch.
    static let forbiddenSymbols = [
        "FileManager", "Process", "Subprocess", "URLSession",
        "Date()", "Date.now", "DispatchQueue", "ProcessInfo", "getenv",
    ]

    @Test(
        "self-contained modules import nothing outside the permitted set",
        arguments: selfContainedModules)
    func importsAreConfined(module: String) throws {
        var offences: [String] = []
        for file in try RepositoryGate.swiftFiles(under: "Sources/\(module)") {
            for line in try RepositoryGate.codeLines(of: file).split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let imported = Self.importedModule(in: trimmed) else { continue }
                guard !Self.permittedImports.contains(imported) else { continue }
                offences.append(
                    "\(RepositoryGate.repositoryRelativePath(file)): import \(imported)")
            }
        }
        #expect(
            offences.isEmpty,
            """
            \(module) is a pure module: it may not import anything that can reach the \
            filesystem, a process, the network, or a clock. Move the effect behind a \
            boundary and inject it.
            \(offences.sorted().joined(separator: "\n"))
            """
        )
    }

    @Test("effect-free modules name no effectful symbol", arguments: effectFreeModules)
    func effectfulSymbolsAreAbsent(module: String) throws {
        var offences: [String] = []
        for file in try RepositoryGate.swiftFiles(under: "Sources/\(module)") {
            let code = try RepositoryGate.codeLines(of: file)
            for symbol in Self.forbiddenSymbols where code.contains(symbol) {
                offences.append("\(RepositoryGate.repositoryRelativePath(file)): \(symbol)")
            }
        }
        #expect(
            offences.isEmpty,
            "\(module) must stay free of ambient effects.\n\(offences.sorted().joined(separator: "\n"))"
        )
    }

    /// The module named by an `import` line, ignoring access modifiers and attributes.
    private static func importedModule(in line: String) -> String? {
        var rest = Substring(line)
        for modifier in [
            "public ", "package ", "internal ", "fileprivate ", "private ", "@testable ",
            "@preconcurrency ",
        ] {
            while rest.hasPrefix(modifier) { rest = rest.dropFirst(modifier.count) }
        }
        guard rest.hasPrefix("import ") else { return nil }
        let name = rest.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
        // `import struct Foundation.Data` names the module second.
        let words = name.split(separator: " ")
        let moduleWord = words.count > 1 ? words[1] : (words.first ?? "")
        return String(moduleWord.split(separator: ".").first ?? moduleWord)
    }
}
