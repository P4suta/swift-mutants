// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutantsConfig

/// The settings a project wrote down, read from the file it keeps them in.
///
/// Here rather than in `SwiftMutantsConfig` because reading a file is I/O and that module is
/// one of the two this repository keeps free of it - what a setting *means* is decided
/// there, and where the bytes came from is decided here.
///
/// Every command that has a configuration reads it through this. The gate in
/// `ConfigurationGateTests` is what keeps that true: the parser, the decoder and the
/// unknown-key refusal were all built, all tested, and called by nothing, so every command
/// ran against `Configuration()` and the file was inert on every path. Nothing said so,
/// because a setting that is ignored and a setting that is obeyed produce the same output
/// until the day they do not.
enum ConfigurationFile {

    /// What the file is called, in the root of the package being measured.
    ///
    /// The package's own root and nowhere else. A tool that searched upwards would behave
    /// differently depending on where the person running it happened to be standing, and a
    /// configuration that changes with the current directory is one nobody can reason about.
    static let name = ".swift-mutants.toml"

    /// What the project wrote down, or the defaults when it wrote nothing.
    ///
    /// Absent is not an error: a configuration is a place to start editing rather than a
    /// prerequisite, and most packages need none of it.
    ///
    /// Present and wrong *is* an error, and a loud one. A run that silently carried on with
    /// the defaults would measure a program the person asking had excluded half of, and
    /// report a score about it. Every refusal names the file and the line, because the
    /// parser kept the positions for exactly this.
    static func read(in root: URL) throws -> Configuration {
        do {
            return try Self.decoded(in: root)
        } catch {
            // Said here rather than thrown, because the argument parser has one exit code
            // for every error it does not recognise and it is `1` - the number this tool
            // reserves for "a gate you asked for was not met". A configuration this tool
            // could not read is not a score; it is this tool or this configuration being
            // wrong, which the contract numbers `2`.
            let leaving = Gate.unfinished(error)
            FileHandle.standardError.write(Data((leaving.said + "\n").utf8))
            throw ExitCode(leaving.code)
        }
    }

    /// What the file says, refused with the line when it does not say a configuration.
    ///
    /// Apart from ``read(in:)`` so that the refusal is a value a test can read rather than
    /// something already turned into an exit. What it says is the part that gets acted on.
    static func decoded(in root: URL) throws -> Configuration {
        let location = root.appending(path: Self.name)
        guard let bytes = try? Data(contentsOf: location) else {
            // Unreadable rather than absent is still absent as far as this can tell, and
            // the difference is not worth a failure: a directory nobody can read is a
            // problem the next phase will hit with a better error than this one could give.
            return Configuration()
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw ValidationError(
                "\(Self.name) is not UTF-8, so nothing in it could be read.")
        }
        // Two refusals, and they are about different things: the parser objects to text
        // that is not TOML, and the decoder objects to TOML that is not a configuration.
        // Both carry the line, and both say the file's name, because a message that begins
        // "line 3" without saying line 3 of what is a message somebody has to go looking
        // for the subject of.
        let document: TOMLTable
        do {
            document = try TOMLParser.parse(text)
        } catch {
            throw ValidationError("\(Self.name): \(error)")
        }
        do {
            return try Configuration(document)
        } catch {
            throw ValidationError("\(Self.name): \(error)")
        }
    }
}
