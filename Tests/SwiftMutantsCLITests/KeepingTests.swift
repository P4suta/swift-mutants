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

    @Test("says where the copy is when it is asked to keep it")
    func saysWhereItIs() {
        let workspace = URL(filePath: "/tmp/swift-mutants-1234")
        #expect(
            Narration.kept(workspace) == "the copy is kept at /tmp/swift-mutants-1234"
        )
    }
}
