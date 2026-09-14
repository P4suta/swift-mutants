// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// What this build calls itself.
///
/// In `Core` rather than in the command, because a report carries it and a report is a
/// value: anything reading one has to be able to say which build made it without linking
/// the command-line tool.
public enum Version {

    /// Read from the VERSION file at release time; a development build says so.
    public static let current = "0.0.0-dev"
}
