#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 swift-mutants contributors
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# A SwiftPM artifact bundle: the binary, for both architectures, with the manifest that
# lets `swift package experimental-install` and a Homebrew tap take it without a compiler.
#
# Both architectures in one universal binary rather than two bundle variants, because a
# tap that has to choose is a tap that chooses wrong on somebody's machine.
set -euo pipefail

tag="${1:?usage: make-bundle.sh vX.Y.Z}"
version="${tag#v}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

bundle=".build/artifacts/swift-mutants.artifactbundle"
inside="$bundle/swift-mutants-$version-macos/bin"
rm -rf "$bundle"
mkdir -p "$inside"

for arch in arm64 x86_64; do
    swift build --configuration release --arch "$arch" --product swift-mutants
done
lipo -create -output "$inside/swift-mutants" \
    "$(swift build --configuration release --arch arm64 --show-bin-path)/swift-mutants" \
    "$(swift build --configuration release --arch x86_64 --show-bin-path)/swift-mutants"

# The licences travel with the binary. A bundle that carries a program and not its terms
# is a bundle somebody has to go and look them up for.
cp LICENSE-MIT LICENSE-APACHE THIRD_PARTY_NOTICES.md "$bundle/" 2>/dev/null || true

cat > "$bundle/info.json" <<JSON
{
  "schemaVersion": "1.0",
  "artifacts": {
    "swift-mutants": {
      "version": "$version",
      "type": "executable",
      "variants": [
        {
          "path": "swift-mutants-$version-macos/bin",
          "supportedTriples": ["arm64-apple-macosx", "x86_64-apple-macosx"]
        }
      ]
    }
  }
}
JSON

( cd .build/artifacts && zip -qry "$root/swift-mutants.artifactbundle.zip" swift-mutants.artifactbundle )
shasum -a 256 swift-mutants.artifactbundle.zip > swift-mutants.artifactbundle.zip.sha256

printf 'bundled %s\n' "$version"
cat swift-mutants.artifactbundle.zip.sha256
