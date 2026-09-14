// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsCLI

/// What a run leaves behind when it is asked to.
///
/// A run happens inside a copy that is deleted when it ends, which is right: the copy is
/// large, and a tool that filled somebody's temporary directory with abandoned packages
/// would be a tool people stop running. But when a run fails, that copy is the only place
/// the failure exists - the instrumented sources, the build log, the tree the compiler was
/// actually looking at - and deleting it takes the evidence with it.
///
/// So keeping it is a decision the person watching makes, and the path is printed whether
/// or not the run succeeded. A path nobody was told about is the same as no path.
@Suite("Keeping the copy")
struct KeepingTests {

    /// Deleting hundreds of megabytes of somebody's disk is a thing to mention.
    @Test("says how many abandoned copies it cleared up")
    func saysWhatItCleared() {
        #expect(
            Narration.swept(1) == "cleared up 1 copy left behind by a run that was interrupted")
        #expect(
            Narration.swept(7)
                == "cleared up 7 copies left behind by runs that were interrupted")
    }

    /// Relative to the package, because that is how somebody refers to it afterwards - in
    /// a commit, in a CI step, in a sentence to a colleague.
    @Test("says where a document it wrote went, as the repository names it")
    func saysWhereADocumentWent() {
        #expect(
            Narration.published(
                URL(filePath: "/work/pkg/reports/mutation/mutation.html"),
                relativeTo: URL(filePath: "/work/pkg")
            ) == "wrote reports/mutation/mutation.html")
    }

    /// And plainly when it is somewhere else entirely, rather than by a path that starts
    /// with several `..`.
    @Test("says where a document outside the package went")
    func saysWhereAnOutsideDocumentWent() {
        #expect(
            Narration.published(
                URL(filePath: "/elsewhere/mutation.html"), relativeTo: URL(filePath: "/work/pkg")
            ) == "wrote /elsewhere/mutation.html")
    }

    @Test("says where the copy is when it is asked to keep it")
    func saysWhereItIs() {
        let workspace = URL(filePath: "/tmp/swift-mutants-1234")
        #expect(
            Narration.kept(workspace) == "the copy is kept at /tmp/swift-mutants-1234"
        )
    }
}

/// Forgetting what is kept about a package.
///
/// Everything this tool remembers lives outside the repository, which means nobody can
/// delete it by deleting a directory they can see. So there is a command, and it says how
/// much there was rather than claiming to have done something when there was nothing.
@Suite("Forgetting a package")
struct ForgettingTests {

    @Test("says nothing was kept when nothing was")
    func nothingKept() {
        #expect(Narration.forgotten(0) == "nothing was being kept about this package.")
    }

    @Test("says how much it forgot")
    func saysHowMuch() {
        #expect(
            Narration.forgotten(3)
                == "forgot 3 of the things being kept about this package.")
    }
}
