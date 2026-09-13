// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Foundation is re-exported because `URL` appears in this gate's public surface;
// InternalImportsByDefault would otherwise keep it internal.
public import Foundation

/// Locates this repository and reads it, so that a gate can assert facts about the tree
/// rather than about a value some other test constructed.
///
/// The root is found by walking up from this file until a directory holding
/// `Package.swift` appears, which is the one anchor that survives being run from a
/// scratch path, from an IDE, and from CI alike. Nothing here is part of the shipped
/// tool; it is test support and lives in the test target on purpose.
public enum RepositoryGate {

    /// The absolute path of the repository root.
    public static let root: URL = {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        fatalError(
            "no Package.swift above \(#filePath): the repository gates cannot locate the tree they check"
        )
    }()

    /// Every `.swift` file under a repository-relative directory, in sorted order.
    ///
    /// Sorted because a gate that fails should name the same file first on every machine;
    /// `FileManager` makes no ordering promise.
    public static func swiftFiles(under relativePath: String) throws -> [URL] {
        let base = root.appending(path: relativePath)
        guard
            let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey])
        else {
            throw GateError.unreadableDirectory(relativePath)
        }
        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The code of a file, with comment-only lines removed.
    ///
    /// A gate asks whether a name is *used*, and prose that explains why it is not used
    /// is not a use - `SourceSpan`'s own documentation names `SyntaxIdentifier` precisely
    /// to say it must never appear. Stripping is deliberately conservative: it drops
    /// whole lines that are comments and nothing else. A trailing comment after real code
    /// still counts, which can produce a false failure, and a false failure is the
    /// direction a gate should err in.
    public static func codeLines(of url: URL) throws -> String {
        var inBlockComment = false
        var kept: [Substring] = []
        for line in try contents(of: url).split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBlockComment {
                if trimmed.hasSuffix("*/") { inBlockComment = false }
                continue
            }
            if trimmed.hasPrefix("//") { continue }
            if trimmed.hasPrefix("/*") {
                if !trimmed.hasSuffix("*/") { inBlockComment = true }
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// Directories a gate never looks inside.
    ///
    /// `Fixtures` is the corpus: it is input, some of it is broken on purpose, and a rule
    /// this repository holds itself to is not a rule its test data has to obey.
    public static let unscannedDirectories: Set<String> = [
        ".build", ".git", ".swiftpm", "vendor", "Fixtures", "DerivedData", "reports", "dist",
    ]

    /// Every text file in the tree, in sorted order.
    ///
    /// Extension-based rather than content-sniffing, so that adding a binary format to the
    /// tree cannot make a gate start reading it as UTF-8 and fail for the wrong reason.
    public static let textFileExtensions: Set<String> = [
        "swift", "toml", "yml", "yaml", "md", "sh", "json", "txt", "cfg", "plist", "xml",
    ]

    /// Text files a gate should read, including dotfiles with no extension that are
    /// nonetheless configuration this project owns.
    public static func textFiles() throws -> [URL] {
        guard
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else {
            throw GateError.unreadableDirectory(".")
        }
        var found: [URL] = []
        for case let url as URL in walker {
            if unscannedDirectories.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard
                textFileExtensions.contains(url.pathExtension)
                    || knownExtensionlessFiles.contains(url.lastPathComponent)
            else { continue }
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }

    /// Configuration files this project owns that carry no extension.
    public static let knownExtensionlessFiles: Set<String> = [
        ".gitignore", ".yamllint", ".swift-format", ".gitattributes", "Dockerfile",
    ]

    /// The whole text of a file, comments included.
    public static func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// The path a failure message should print: relative to the root, never absolute.
    public static func repositoryRelativePath(_ url: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath) ? String(url.path.dropFirst(rootPath.count)) : url.path
    }

    /// A tree this gate could not read.
    public enum GateError: Error, CustomStringConvertible {
        /// A directory the gate was asked to walk and could not.
        case unreadableDirectory(String)

        /// The failure, naming the root it was resolved against.
        public var description: String {
            switch self {
            case .unreadableDirectory(let path):
                "cannot enumerate \(path) under \(RepositoryGate.root.path)"
            }
        }
    }
}
