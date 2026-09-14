// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import ArgumentParser
public import SwiftMutantsCore

/// `--shard 2/5`.
///
/// Written the way people write it, and refused when it is not a share: `0/5` and `6/5` are
/// each somebody's off-by-one, and a run that silently measured nothing or everything
/// instead would be a run whose number nobody could account for.
extension Shard: ExpressibleByArgument {

    /// Reads `2/5`, and refuses anything that is not a share.
    public init?(argument: String) {
        let parts = argument.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let index = Int(parts[0]), let count = Int(parts[1]) else {
            return nil
        }
        self.init(index, of: count)
    }

    /// What a person types, for the help to show.
    public var defaultValueDescription: String { description }
}
