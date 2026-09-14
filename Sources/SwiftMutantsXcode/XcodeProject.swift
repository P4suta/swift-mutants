// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// What an Xcode project or workspace says about itself.
///
/// Reading rather than driving: everything here is a function of what `xcodebuild` printed,
/// so the parts that can be wrong can be wrong in a test rather than in somebody's project.
///
/// The project file itself is never parsed. A `.pbxproj` is a format Xcode owns and changes,
/// and this needs nothing out of it: the runtime a mutant is woken by lives inside the file
/// it mutates, so there is no target membership to work out. `-list -json` and the document
/// `build-for-testing` writes are the whole of what this reads.
public enum XcodeProject {

    /// A project this tool cannot work with, or an answer it will not guess at.
    public struct Unusable: Error, Hashable, CustomStringConvertible {

        /// What is wrong, in the words a fix needs.
        public let description: String
    }

    /// The schemes in what `xcodebuild -list -json` printed.
    ///
    /// The document is found inside the output rather than assumed to be all of it: Xcode
    /// prints a timestamped note about run destinations first on some machines, and a
    /// reader that decoded the whole output would fail on every project - with a message
    /// about malformed JSON rather than about the note, which is an afternoon lost.
    public static func schemes(in output: String) throws(Unusable) -> [String] {
        guard let start = output.firstIndex(of: "{"),
            let parsed = try? JSONSerialization.jsonObject(
                with: Data(output[start...].utf8)),
            let root = parsed as? [String: Any]
        else {
            throw Unusable(
                description: """
                    `xcodebuild -list -json` did not print a list of schemes. What it did \
                    print was:
                    \(output.isEmpty ? "  (nothing)" : output)
                    """
            )
        }
        // A project and a workspace say the same thing under different keys, and a tool
        // that knew one of them would work on half of what people have.
        let container = (root["project"] ?? root["workspace"]) as? [String: Any]
        let schemes = (container?["schemes"] as? [String]) ?? []
        guard !schemes.isEmpty else {
            throw Unusable(
                description: "this project has no schemes in it, so there is nothing to run")
        }
        return schemes
    }

    /// The scheme somebody meant.
    ///
    /// One scheme is not a choice, so it is taken. Several is, and guessing would be a run
    /// measuring a target nobody asked about - so it says what the choices are instead, and
    /// a name that is not among them is answered with the list rather than with a refusal.
    public static func scheme(_ asked: String?, among schemes: [String]) throws(Unusable) -> String
    {
        if let asked {
            guard schemes.contains(asked) else {
                throw Unusable(
                    description: """
                        this project has no scheme called \(asked). It has:
                        \(schemes.map { "  \($0)" }.joined(separator: "\n"))
                        """
                )
            }
            return asked
        }
        guard schemes.count == 1, let only = schemes.first else {
            throw Unusable(
                description: """
                    this project has \(schemes.count) schemes, so say which one with \
                    --scheme:
                    \(schemes.map { "  \($0)" }.joined(separator: "\n"))
                    """
            )
        }
        return only
    }

    /// The document `build-for-testing` wrote into a products directory.
    ///
    /// Found rather than reconstructed from the destination: the name carries a platform
    /// version this tool never sees, and a path it had built itself would be right until
    /// somebody updated Xcode.
    public static func xctestrun(in products: URL) throws(Unusable) -> URL {
        let names =
            ((try? FileManager.default.contentsOfDirectory(atPath: products.path)) ?? [])
            .filter { $0.hasSuffix(".xctestrun") }
            .sorted()
        // Zero and several are different problems with different fixes, so they get
        // different sentences - but one check, because "exactly one" is the condition and
        // two guards for it is one of them that can never fire.
        guard names.count == 1 else {
            throw Unusable(
                description: names.isEmpty
                    ? """
                    `xcodebuild build-for-testing` wrote no .xctestrun into \
                    \(products.path), so there is nothing to run
                    """
                    : """
                    `xcodebuild build-for-testing` wrote \(names.count) .xctestrun \
                    documents, so this scheme covers more than one platform and a run \
                    would be about whichever sorted first. Narrow it with --destination:
                    \(names.map { "  \($0)" }.joined(separator: "\n"))
                    """
            )
        }
        return products.appending(path: names[0])
    }
}
