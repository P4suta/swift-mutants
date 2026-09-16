// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsConfig

/// A setting this build cannot honour is refused, not accepted and ignored.
///
/// Two settings named something this build could not do, and stored the answer anyway. A
/// project that wrote either got exactly the run they would have got without it, and no way
/// to discover that short of reading the source of this tool.
///
/// So each is refused with the line it is on, which is how everything else this decoder
/// cannot honour is treated. `extreme` used to be here too and is not, because it is built.
@Suite("A setting this build cannot honour")
struct UnbuiltSettingTests {

    static func decode(_ text: String) throws -> Configuration {
        try Configuration(TOMLParser.parse(text))
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

    /// And what is built is accepted, which is the other half of the claim: this suite is
    /// about settings that cannot be honoured, not about settings that are unusual.
    @Test("accepts a setting this build does honour")
    func acceptsWhatIsBuilt() throws {
        let configuration = try Self.decode(
            """
            [mutation]
            extreme = true
            """)
        #expect(configuration.mutation.extreme)
    }
}
