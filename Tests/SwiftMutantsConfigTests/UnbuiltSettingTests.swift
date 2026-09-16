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
