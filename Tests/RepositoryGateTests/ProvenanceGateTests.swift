// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTestKit
import Testing

/// Gates over what every file in the tree must carry.
///
/// `reuse lint` checks the same SPDX rule across every file type, but it runs in
/// `mise run check` rather than in the inner loop, and its message names a rule rather
/// than a fix. This gate is the fast, specific half of the same promise.
@Suite("Provenance gate")
struct ProvenanceGateTests {

    @Test("every Swift file carries an SPDX header")
    func spdxHeaders() throws {
        var missing: [String] = []
        for directory in ["Sources", "Tests"] {
            for file in try RepositoryGate.swiftFiles(under: directory) {
                let head = try RepositoryGate.contents(of: file).prefix(400)
                guard head.contains("SPDX-FileCopyrightText"),
                    head.contains("SPDX-License-Identifier")
                else {
                    missing.append(RepositoryGate.repositoryRelativePath(file))
                    continue
                }
            }
        }
        #expect(
            missing.isEmpty,
            """
            Every file needs the two SPDX lines, so that the tree stays REUSE-compliant \
            and a consumer can tell what they are allowed to do with any single file:
              // SPDX-FileCopyrightText: 2026 swift-mutants contributors
              // SPDX-License-Identifier: MIT OR Apache-2.0
            Missing from: \(missing.sorted().joined(separator: ", "))
            """
        )
    }

    /// The repository is English-only, in every file and not only in the Swift.
    ///
    /// Conversation about this project happens in Japanese; the tree does not. A comment,
    /// a task description, a commit message or a lint rule written in another language is
    /// a defect here, because the audience for the repository is whoever reads it next
    /// and they were not in the conversation. SwiftLint carries the same rule for `.swift`
    /// files so it fires during `mise run check`; this one covers every text file and runs
    /// in the inner loop, and the two disagree only when one of them has been broken.
    @Test("the repository contains no CJK text")
    func repositoryIsEnglish() throws {
        let cjk = /[\x{3040}-\x{309F}\x{30A0}-\x{30FF}\x{4E00}-\x{9FFF}\x{AC00}-\x{D7AF}]/
        var offenders: [String] = []
        for file in try RepositoryGate.textFiles() {
            guard let text = try? RepositoryGate.contents(of: file) else { continue }
            if text.contains(cjk) {
                offenders.append(RepositoryGate.repositoryRelativePath(file))
            }
        }
        #expect(
            offenders.isEmpty,
            """
            The codebase is English-only: source, comments, identifiers, documentation, \
            configuration and commit messages alike.
            Offending files: \(offenders.sorted().joined(separator: ", "))
            """
        )
    }
}
