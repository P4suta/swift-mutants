// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTestKit
import Testing

/// Keeps every command reading the file the project wrote its settings in.
///
/// The parser, the decoder and the unknown-key refusal were all built and all tested, and
/// nothing called any of them. Every command started from `Configuration()`, so `include`,
/// `exclude`, `operators`, `profile`, `expect` and `custom` were inert on every path - and
/// nothing said so, because a setting that is ignored and a setting that is obeyed produce
/// the same output until the day they do not. It was found by a project that wrote 320
/// `[[mutation.custom]]` rows and watched `list` print exactly the same three numbers.
///
/// A test of one command would not have caught it and would not catch it coming back: the
/// mistake is not getting the reading wrong, it is not reaching for it. So the gate is
/// about the shape of the code rather than about an answer - the same instrument this
/// repository already points at subprocess spawning, and for the same reason.
///
/// The second half matters as much as the first. `list` is documented as saying what a run
/// would do without doing it, so a `list` that read the defaults while `run` read the file
/// would confidently describe a different run - and `list` is the command people check
/// with. Ignoring the file everywhere is a bug; ignoring it in the command people believe
/// is a trap.
@Suite("Every command reads the project's settings")
struct ConfigurationGateTests {

    /// The one place a configuration may be conjured out of nothing: the reader, which
    /// returns the defaults for a package that wrote no file.
    static let readsTheFile = "ConfigurationFile.swift"

    @Test("builds no configuration out of thin air outside the file reader")
    func nobodyDefaultsTheConfiguration() throws {
        var offenders: [String] = []
        for file in try RepositoryGate.swiftFiles(under: "Sources/SwiftMutantsCLI") {
            guard file.lastPathComponent != Self.readsTheFile else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            // `CommandConfiguration()` is ArgumentParser's, and is a different word that
            // happens to end the same way.
            let bare = text.ranges(of: "Configuration()").filter { range in
                !text[text.startIndex..<range.lowerBound].hasSuffix("Command")
            }
            if !bare.isEmpty { offenders.append(file.lastPathComponent) }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.joined(separator: ", ")) builds a configuration from nothing rather \
            than reading \(ConfigurationFileName.value). Whatever the project wrote in that \
            file - the directories it excluded, the operators it turned off, the mutations \
            it wrote itself - will be silently absent from whatever this command reports.
            """
        )
    }

    /// Every command that lists or measures reads it. Named one at a time rather than
    /// inferred, because a command added later should have to appear here, and appearing
    /// here is where somebody notices that it has a configuration to read.
    @Test(
        "reads it in every command that says what would be measured",
        arguments: ["RunCommand.swift", "ListCommand.swift", "WhySkippedCommand.swift"])
    func everyMeasuringCommandReadsIt(_ name: String) throws {
        let file = RepositoryGate.root
            .appending(path: "Sources/SwiftMutantsCLI").appending(path: name)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(
            text.contains("ConfigurationFile.read(in:"),
            "\(name) never reads \(ConfigurationFileName.value)")
    }
}

/// The file's name, spelled once here so this gate and the reader cannot drift apart
/// without one of them failing to compile.
enum ConfigurationFileName {
    static let value = ".swift-mutants.toml"
}
