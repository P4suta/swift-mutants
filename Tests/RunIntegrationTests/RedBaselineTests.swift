// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsEngine
import Testing

/// Whose failure it is when the tests fail with nothing awake.
///
/// A suite of its own because the two cases are a pair and only make sense read together:
/// the same symptom, opposite blame, and a sentence each that sends a reader to the right
/// place. Split out of the whole-run suite when it outgrew it.
@Suite("A red baseline, and whose it is")
struct RedBaselineTests {

    /// A score is an answer about a program, so a tree that does not behave like the one
    /// the user wrote must stop the run rather than produce one.
    ///
    /// And it must say *whose* it is. The suite failing with nothing awake has two causes
    /// that look identical from inside the copy - the tests were already failing, or
    /// instrumentation broke them - and they are somebody else's problem in one case and
    /// this tool's in the other. These two tests are the pair: same symptom, opposite
    /// blame, and each asserts the sentence that would send a reader to the right place.
    @Test("says the tests were already failing, when they were", .tags(.integration))
    func redBaseline() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }
        try RunIntegrationTests.write(
            """
            import Testing
            @testable import Subject

            @Suite("Subject")
            struct SubjectTests {
                @Test("is wrong") func wrong() { #expect(atLeast(1, 3)) }
            }
            """, to: fixture.root.appending(path: "Tests/SubjectTests/SubjectTests.swift"))

        let failure = await #expect(throws: RunError.self) {
            try await RunIntegrationTests.run(fixture)
        }
        // Not "the instrumented tree does not behave like the one you wrote", which is what
        // this said before anybody checked: the tree behaves exactly like the one the user
        // wrote, and the one the user wrote is red. Blaming instrumentation for somebody
        // else's failing test sends them to read a diff that has nothing wrong with it.
        #expect(
            failure?.description.contains("your tests do not pass as you wrote them") == true,
            "\(failure?.description ?? "no failure")")
        #expect(failure?.description.contains("does not behave like the one you wrote") == false)
    }

    /// The other half: a suite that passes as written and fails once instrumented.
    ///
    /// A test that reads its own source text does this, and it is not a contrived shape -
    /// this repository has a whole tier of them, and they are why `mise run dogfood` skips
    /// `RepositoryGateTests`. Instrumentation appends a runtime to every file it touches
    /// by design, so a test asserting on the bytes of a file is asserting on something the
    /// tool changed on purpose.
    @Test("says instrumentation broke them, when it did", .tags(.integration))
    func instrumentationBrokeThem() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }
        try RunIntegrationTests.write(
            """
            import Foundation
            import Testing

            @testable import Subject

            @Suite("Subject")
            struct SubjectTests {
                @Test("holds at the boundary") func boundary() {
                    #expect(atLeast(3, 3))
                    #expect(!atLeast(2, 3))
                }

                /// Passes as written and fails instrumented, which is the whole point of it.
                @Test("the source says what it says") func sourceText() throws {
                    let source = URL(filePath: #filePath)
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .appending(path: "Sources/Subject/Subject.swift")
                    let text = try String(contentsOf: source, encoding: .utf8)
                    #expect(!text.contains("__sm_"))
                }
            }
            """, to: fixture.root.appending(path: "Tests/SubjectTests/SubjectTests.swift"))

        let failure = await #expect(throws: RunError.self) {
            try await RunIntegrationTests.run(fixture)
        }
        #expect(
            failure?.description.contains("does not behave like the one you wrote") == true,
            "\(failure?.description ?? "no failure")")
    }
}
