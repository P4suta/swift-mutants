// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsConfig

/// A setting this build cannot honour is refused, not accepted and ignored.
///
/// `extreme` asks for whole function bodies to be replaced - the operator with the best
/// signal-to-noise in the literature, and the one this build does not have. It was read,
/// validated as a boolean, stored, written into the file `init` produces with a paragraph
/// explaining what it finds, and then used by nothing at all.
///
/// A project that set it got exactly the run they would have got without it, and no way to
/// discover that short of reading the source of this tool. That is the failure this project
/// exists to refuse, arriving in the settings file the tool itself wrote.
///
/// So it is refused with the line it is on, which is how every other thing this decoder
/// cannot honour is treated. `extreme = false` is accepted, because that is what this build
/// does - saying no to a request for nothing would be pedantry rather than honesty.
@Suite("A setting this build cannot honour")
struct UnbuiltSettingTests {

    static func decode(_ text: String) throws -> Configuration {
        try Configuration(TOMLParser.parse(text))
    }

    @Test("is refused rather than accepted and ignored")
    func refusesExtreme() {
        #expect(throws: ConfigurationError.self) {
            try Self.decode(
                """
                [mutation]
                extreme = true
                """)
        }
    }

    /// With the line, because a settings file is edited in a text editor and "somewhere in
    /// your configuration" is not a place.
    @Test("says which line to go to")
    func namesTheLine() throws {
        let thrown = #expect(throws: ConfigurationError.self) {
            try Self.decode(
                """
                version = 1

                [mutation]
                profile = "strong"
                extreme = true
                """)
        }
        #expect(thrown?.line == 5, "\(thrown?.description ?? "nothing was thrown")")
    }

    /// And says what it is, so nobody reads it as a typo and tries a different spelling.
    @Test("says the operator is not built rather than that the key is wrong")
    func saysWhatIsWrong() throws {
        let thrown = #expect(throws: ConfigurationError.self) {
            try Self.decode(
                """
                [mutation]
                extreme = true
                """)
        }
        let said = thrown?.reason.lowercased() ?? ""
        #expect(said.contains("extreme"), "\(said)")
        #expect(said.contains("build") || said.contains("version"), "\(said)")
    }

    /// The test command is the same shape of claim: it is stored and honoured by nothing,
    /// because a run builds the bundles once and launches them directly.
    @Test("refuses a test command this build cannot run")
    func refusesCommand() {
        #expect(throws: ConfigurationError.self) {
            try Self.decode(
                """
                [test]
                command = ["swift", "test"]
                """)
        }
    }

    /// And says where the thing that does work is, because somebody writing this wanted to
    /// narrow their suite and there is a way to do that.
    @Test("points at the arguments that do reach the tests")
    func pointsAtArguments() throws {
        let thrown = #expect(throws: ConfigurationError.self) {
            try Self.decode("[test]\ncommand = [\"swift\", \"test\"]")
        }
        #expect(thrown?.reason.contains("--") == true, "\(thrown?.reason ?? "")")
    }

    /// Memory is refused on a measurement rather than a belief: under `ulimit -v 262144`
    /// this platform reports `unlimited` and lets a process take four gigabytes, so the
    /// limit it would be built on does not limit anything.
    @Test("refuses a memory bound this platform will not enforce")
    func refusesMemory() {
        #expect(throws: ConfigurationError.self) {
            try Self.decode(
                """
                [test]
                memory = "2GiB"
                """)
        }
    }

    /// The value is not read first. Complaining that `2 gigs` is not a size would send
    /// somebody to correct a number that was never going to be used, and they would then
    /// meet the real refusal on the next run.
    @Test("says the bound is not built rather than that the size is malformed")
    func doesNotGradeTheValue() throws {
        let thrown = #expect(throws: ConfigurationError.self) {
            try Self.decode("[test]\nmemory = \"2 gigs\"")
        }
        #expect(thrown?.reason.contains("memory") == true, "\(thrown?.reason ?? "")")
        #expect(thrown?.reason.contains("is not a size") != true, "\(thrown?.reason ?? "")")
    }

    /// Asking for what this build does is not an error.
    @Test("accepts being told not to do it")
    func acceptsFalse() throws {
        let configuration = try Self.decode(
            """
            [mutation]
            extreme = false
            """)
        #expect(configuration.mutation.extreme == false)
    }
}
