// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import SwiftMutantsCore

/// Which build of this tool an answer came from.
///
/// Every cache key carries it, because a rule may come to mean something new or a verdict
/// may be decided differently, and an answer from one build is not evidence about another.
/// A released build says so with its version.
///
/// A development build does not. `0.0.0-dev` is the same string before and after a change to
/// the thing being developed, so a cache keyed on it would hand yesterday's answers to a
/// tool that no longer agrees with them - and the person most likely to be hurt is whoever
/// is changing this code, measuring it against itself, and trusting the number.
public enum ToolIdentity {

    /// What a released version looks like.
    static let developmentSuffix = "-dev"

    /// The name this build should be remembered by.
    ///
    /// The version alone for a release, because hashing megabytes of binary to rediscover a
    /// number already written down is work for nothing. The version and a digest of the
    /// executable for a development build, because that changes exactly when the tool does.
    ///
    /// A build it cannot read is a build it cannot vouch for, and it says so with a name
    /// nothing will match rather than falling back to a version that means nothing. Two runs
    /// then never agree, which costs a cache and cannot cost an answer.
    public static func of(_ version: String, at executable: URL) -> String {
        guard version.hasSuffix(Self.developmentSuffix) else { return version }
        guard let data = try? Data(contentsOf: executable) else {
            return "\(version)+unknown-\(UUID().uuidString)"
        }
        return "\(version)+\(Digest.of(data).hexadecimal)"
    }

    /// The name the running build should be remembered by.
    ///
    /// Worked out once. A development build's name is a digest of the executable, and
    /// hashing it again for every key would be hashing the same megabytes a thousand times.
    public static let current: String = Self.of(Version.current, at: Self.runningExecutable)

    /// Where the running program is.
    ///
    /// `Bundle.main.executableURL` rather than the first argument, because the first
    /// argument is whatever the shell was told and may be a relative path, a symlink, or a
    /// name found on `PATH`.
    static var runningExecutable: URL {
        Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments.first ?? "")
    }
}
