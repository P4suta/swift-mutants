// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import ArgumentParser
import SwiftMutantsConfig
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsCLI

/// Reading the settings a project wrote down.
///
/// The parser, the decoder and the unknown-key refusal were all built and all tested, and
/// nothing called any of them: every command started from `Configuration()` and the file was
/// inert on every path. A project that had excluded a directory was told about mutants in
/// it, a project that had written `[[mutation.custom]]` rows got none of them, and the tool
/// said nothing either time - the shape of failure this repository keeps finding, where the
/// wrong answer and the right one are the same output.
///
/// Reported by a project migrating 320 hand-written mutations into `[[mutation.custom]]`:
/// the three numbers `list` printed were identical before and after adding all of them.
///
/// The part worth keeping in mind while reading this file is *why every command reads it*
/// rather than only `run`. `list` is documented as saying what a run would do without doing
/// it, so `list` reading the defaults while `run` read the file would make the two disagree
/// - and `list` is the one people believe. Ignoring a file everywhere is a bug; ignoring it
/// in the command people check with is a trap.
@Suite("The file a project keeps its settings in")
struct ConfigurationFileTests {

    static func scratch() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "swift-mutants-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func writing(_ text: String) throws -> URL {
        let root = try Self.scratch()
        try text.write(
            to: root.appending(path: ConfigurationFile.name), atomically: true, encoding: .utf8)
        return root
    }

    @Test("reads a setting the project wrote down")
    func readsTheFile() throws {
        let root = try Self.writing(
            """
            [mutation]
            profile = "strong"
            exclude = ["Sources/Generated/**"]
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let configuration = try ConfigurationFile.decoded(in: root)
        #expect(configuration.mutation.profile == .strong)
        #expect(configuration.mutation.exclude.map(\.description) == ["Sources/Generated/**"])
    }

    /// The rows a project writes because they encode what its code is *for* - that the
    /// opposite of a direction is a half turn, that a step distance wraps because directions
    /// are a circle. A generator working from syntax cannot propose those, and a file that
    /// was never read meant a project could write three hundred of them and measure none.
    @Test("reads the mutations a project wrote itself")
    func readsCustomMutants() throws {
        let root = try Self.writing(
            """
            [[mutation.custom]]
            file = "Sources/Compass/Direction.swift"
            find = "case .north: return .south"
            replace = "case .north: return .east"
            reason = "the opposite of north is half a turn away, not a quarter"
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let custom = try ConfigurationFile.decoded(in: root).mutation.custom
        #expect(custom.count == 1)
        #expect(custom.first?.file == "Sources/Compass/Direction.swift")
        #expect(custom.first?.reason.contains("half a turn") == true)
    }

    /// The promise the parser's bookkeeping exists to keep. The commonest thing a
    /// configuration contains is a key nobody meant to write, and a tool that ignored it
    /// would let a project believe the setting had been in effect all along.
    @Test("refuses a key it does not know, and says which line it is on")
    func refusesAnUnknownKey() throws {
        let root = try Self.writing(
            """
            [mutation]
            profile = "strong"
            nosuchkey = 1
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        var said = ""
        do {
            _ = try ConfigurationFile.decoded(in: root)
            Issue.record("an unknown key was accepted")
        } catch {
            said = "\(error)"
        }
        #expect(said.contains("nosuchkey"), "\(said)")
        #expect(said.contains("3"), "the line the key is on is not in: \(said)")
        #expect(said.contains(ConfigurationFile.name), "the file is not named in: \(said)")
    }

    /// A configuration is a place to start editing rather than a prerequisite, so a package
    /// without one is measured with the defaults and told nothing.
    @Test("uses the defaults when the project wrote nothing down")
    func defaultsWithoutAFile() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try ConfigurationFile.decoded(in: root) == Configuration())
    }

    /// A flag is what somebody typed just now, so it wins over what they wrote down once.
    @Test("lets a flag beat the file")
    func flagBeatsFile() throws {
        let root = try Self.writing(
            """
            [execution]
            jobs = 2
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        // Through the parser, because a command's options only hold values once something
        // has put them there - which is also how the flags reach it in a real invocation.
        let command = try RunCommand.parse(["--jobs", "9"])
        #expect(
            command.asked(startingFrom: try ConfigurationFile.decoded(in: root))
                .execution.jobs == 9)
    }

    /// The half that is easy to get wrong, and the one that makes a file useless when it is:
    /// a flag nobody typed must not overwrite what the project wrote down with its own
    /// default. Overlaying unconditionally reads as working - the flags do win - and quietly
    /// undoes every setting the file holds.
    @Test("leaves the file alone where no flag was given")
    func absentFlagLeavesTheFile() throws {
        let root = try Self.writing(
            """
            [execution]
            jobs = 2

            [cache]
            mode = "off"
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = try ConfigurationFile.decoded(in: root)
        let asked = try RunCommand.parse([]).asked(startingFrom: file)
        #expect(asked.execution.jobs == 2)
        #expect(asked.cache.mode == file.cache.mode)
    }

    /// The contract this tool documents: two is "this tool or this configuration is
    /// wrong", and one is a gate somebody asked for. A configuration nobody could read is
    /// the first, and it left as the second until this existed - because an error the
    /// argument parser does not recognise becomes the one number it has.
    @Test("leaves the way a configuration problem should, not the way a low score does")
    func refusingLeavesWithTwo() throws {
        let root = try Self.writing(
            """
            [mutation]
            nosuchkey = 1
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try ConfigurationFile.read(in: root)
            Issue.record("an unknown key was accepted")
        } catch let code as ExitCode {
            #expect(code.rawValue == 2, "exited \(code.rawValue)")
        }
    }
}
