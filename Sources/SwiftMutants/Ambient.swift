// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

enum Ambient {
    static var environment: [String: String] {
        ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("SWIFT_MUTANTS_") && !$0.key.hasPrefix("LLVM_PROFILE_")
                && $0.key != "SWIFTPM_TESTS_SKIP" && $0.key != "XCTestConfigurationFilePath"
        }
    }
}
