// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import ArgumentParser
public import SwiftMutantsConfig

/// `--report json|html|sarif`, as many times as wanted.
extension ReportFormat: ExpressibleByArgument {

    /// What a person may type, in the order the help prints them.
    public static var allValueStrings: [String] { Self.allCases.map(\.rawValue) }
}
