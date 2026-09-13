// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// MemberImportVisibility wants the module that declares `main()` named here, even
// though the type itself comes from ours.
import ArgumentParser
import SwiftMutantsCLI

/// A thin main.
///
/// Everything the command line does lives in `SwiftMutantsCLI`, which a test can drive.
/// An executable target cannot be imported, so anything here is code no test can reach.
@main
struct Main {
    static func main() async {
        await SwiftMutantsCommand.main()
    }
}
