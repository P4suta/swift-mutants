// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

enum Terminal {
    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

enum LegacyConfiguration {
    static func check(packagePath: String) throws {
        let root = URL(filePath: packagePath)
        for name in [".swift-mutants.toml", "swift-mutants.toml"]
        where FileManager.default.fileExists(atPath: root.appending(path: name).path) {
            throw ConfigurationMigration(path: name)
        }
    }
}

private struct ConfigurationMigration: Error, CustomStringConvertible {
    let path: String
    var description: String {
        "\(path) is no longer supported. Move source patterns to --include and --exclude, test selection to --filter and --skip, and deadlines to --timeout, then remove the configuration file. Profiles, caches, coverage selection, sharding, custom mutations, and expected survivors were removed. Existing reports are preserved."
    }
}
