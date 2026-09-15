// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsConfig
import Testing

@testable import SwiftMutantsCLI

/// The file a project starts from.
///
/// The configuration became real today - it was parsed, decoded and tested, and read by
/// nothing - and nothing tells anybody it exists. A setting that works and cannot be
/// discovered is a setting nobody uses, which is the same outcome as one that does not work
/// and costs more to maintain.
///
/// Every setting, commented out, with what it is for beside it. Commented rather than set,
/// because a starter file that turned things on would be this tool making decisions about
/// somebody's package by being run once - and a project that copied it without reading it
/// would be measuring under settings nobody chose.
@Suite("The file a project starts from")
struct StarterConfigurationTests {

    /// The one property that cannot be got wrong by hand: whatever is written has to be
    /// readable by the thing that reads it. A starter file this tool refuses would be a
    /// first impression nobody recovers from.
    @Test("is something this tool can read")
    func itParses() throws {
        #expect(throws: Never.self) {
            _ = try Configuration(TOMLParser.parse(StarterConfiguration.text))
        }
    }

    /// And it changes nothing, because every line of it is commented. A project that ran
    /// `init` and then `run` measures exactly what it measured before.
    @Test("changes nothing until somebody uncomments something")
    func changesNothing() throws {
        #expect(try Configuration(TOMLParser.parse(StarterConfiguration.text)) == Configuration())
    }

    /// Uncommenting is the whole interaction, so the commented lines have to be lines. A
    /// starter file whose examples do not parse once uncommented is worse than none.
    @Test("parses once every example is uncommented")
    func uncommentsCleanly() throws {
        let uncommented = StarterConfiguration.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                // Settings and the table headers above them, which is what a person
                // uncommenting an example actually does: the `[[mutation.expect]]` line is
                // part of the example, and leaving it commented drops its keys into
                // whatever table came before. Prose stays a comment.
                let bare = line.drop(while: { $0 == " " })
                guard bare.hasPrefix("# ") else { return line }
                let rest = bare.dropFirst(2)
                return rest.contains("=") || rest.hasPrefix("[") ? rest : line
            }
            .joined(separator: "\n")
        #expect(throws: Never.self) { _ = try Configuration(TOMLParser.parse(uncommented)) }
    }

    /// Every table the reader knows is mentioned. The failure otherwise is that a setting
    /// exists, works, and nobody finds it - which is where all of them were this morning.
    @Test("mentions every group of settings there is")
    func mentionsEveryGroup() {
        for group in ["[mutation]", "[test]", "[execution]", "[cache]", "[policy]", "[report]"] {
            #expect(StarterConfiguration.text.contains(group), "\(group)")
        }
    }
}
