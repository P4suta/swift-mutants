// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import ArgumentParser
public import SwiftMutantsConfig

/// `--cache auto|on|off`.
///
/// The spelling is the file's, not Swift's: a configuration file and a command line that
/// disagreed about what to call the same setting would be two vocabularies for one idea,
/// and the file's is the one shared with the sibling projects.
extension CacheMode: ExpressibleByArgument {

    /// What a person may type, in the order the help prints them.
    public static var allValueStrings: [String] { Self.allCases.map(\.rawValue) }
}
